import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firestore_service.dart'; // For firestoreProvider

/// Thrown by [AuthService.sendOtp]/[AuthService.verifyOtp] for anything the
/// OTP screen needs to react to specifically (wrong code, lockout) rather
/// than just display as a generic error string.
class OtpException implements Exception {
  OtpException(this.message, {this.attemptsRemaining});

  final String message;
  final int? attemptsRemaining;

  @override
  String toString() => message;
}

/// The phone is locked out (5 wrong attempts) until [lockedUntil].
class OtpLockedException implements Exception {
  OtpLockedException(this.lockedUntil);

  final DateTime lockedUntil;
}

enum AppRole { unauthenticated, user, admin, superadmin }

final firebaseAuthProvider = Provider<FirebaseAuth>(
  (ref) => FirebaseAuth.instance,
);

final authStateChangesProvider = StreamProvider<User?>((ref) {
  return ref.watch(firebaseAuthProvider).authStateChanges();
});

/// The signed-in user's `users/{uid}` doc, or null when logged out.
/// The router uses this to detect an incomplete profile (empty `name`).
final userProfileProvider = StreamProvider<Map<String, dynamic>?>((ref) {
  final user = ref.watch(authStateChangesProvider).value;
  if (user == null) return Stream.value(null);

  return ref
      .watch(firestoreProvider)
      .collection('users')
      .doc(user.uid)
      .snapshots()
      .map((snap) => snap.data());
});

class AuthService {
  AuthService(this._auth, this._db, this._functions);

  final FirebaseAuth _auth;
  final FirebaseFirestore _db;
  final FirebaseFunctions _functions;

  /// Requests a code via the real sendOtp Cloud Function. Returns the
  /// plaintext code when running against the Functions emulator (no real
  /// SMS gateway is wired up yet — see docs/00_PROJECT_OVERVIEW.md §7), so
  /// the OTP screen can show it in a dev-only banner; null in production.
  Future<String?> sendOtp(String phone) async {
    if (!_isValidPhone(phone)) throw Exception('Invalid phone number');
    try {
      final result = await _functions
          .httpsCallable('sendOtp')
          .call<Map<String, dynamic>>({'phone': phone});
      return result.data['devCode'] as String?;
    } on FirebaseFunctionsException catch (e) {
      throw _mapOtpException(e);
    }
  }

  /// Verifies the code via the real verifyOtp Cloud Function, then signs in
  /// with the custom token it mints. Throws [OtpException] for a wrong code
  /// or [OtpLockedException] once the phone is locked out.
  /// Returns true if this phone belongs to a brand-new user (route to name entry).
  Future<bool> verifyOtp(String phone, String code) async {
    final Map<String, dynamic> data;
    try {
      final result = await _functions
          .httpsCallable('verifyOtp')
          .call<Map<String, dynamic>>({'phone': phone, 'code': code});
      data = result.data;
    } on FirebaseFunctionsException catch (e) {
      throw _mapOtpException(e);
    }

    await _auth.signInWithCustomToken(data['customToken'] as String);
    return data['isNewUser'] as bool;
  }

  /// Re-verifies ownership of a *new* phone number (same sendOtp code +
  /// this) before repointing users/{uid}.phone at it — phone is the OTP
  /// login identity, so it can't be changed by a plain Firestore write (the
  /// security rules block that field specifically; see firestore.rules).
  Future<void> changePhone(String phone, String code) async {
    try {
      await _functions.httpsCallable('changePhone').call<Map<String, dynamic>>({
        'phone': phone,
        'code': code,
      });
    } on FirebaseFunctionsException catch (e) {
      throw _mapOtpException(e);
    }
  }

  /// verifyOtp's Cloud Function already creates/updates users/{uid} via the
  /// Admin SDK on the server — nothing left for the client to write here.
  Exception _mapOtpException(FirebaseFunctionsException e) {
    final details = e.details;
    final lockedUntilMs = details is Map
        ? details['lockedUntil'] as int?
        : null;
    if (lockedUntilMs != null) {
      return OtpLockedException(
        DateTime.fromMillisecondsSinceEpoch(lockedUntilMs),
      );
    }
    final attemptsRemaining = details is Map
        ? details['attemptsRemaining'] as int?
        : null;
    return OtpException(
      e.message ?? 'Something went wrong',
      attemptsRemaining: attemptsRemaining,
    );
  }

  Future<void> completeProfile(String name) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw Exception('Not signed in');
    // merge:true — self-heals if the users/{uid} doc is missing (e.g. a
    // stale on-device auth session pointing at data the emulator no longer has).
    await _db.collection('users').doc(uid).set({
      'name': name,
    }, SetOptions(merge: true));
  }

  Future<void> signOut() => _auth.signOut();

  // +993 followed by exactly 8 digits, no more, no less — matches the
  // formatters on both phone-entry TextFields (phone_entry_screen.dart,
  // edit_profile_screen.dart), which already constrain input to digits-only
  // and cap length before it ever reaches here.
  bool _isValidPhone(String phone) {
    return RegExp(r'^\+993\d{8}$').hasMatch(phone);
  }
}

final authServiceProvider = Provider<AuthService>((ref) {
  return AuthService(
    ref.watch(firebaseAuthProvider),
    ref.watch(firestoreProvider),
    FirebaseFunctions.instance,
  );
});

/// Custom claims (role/storeIds) are baked into the ID token at issuance —
/// promoting a user to admin, or granting/revoking a store on an existing
/// admin (setStoreAdmin) updates both Firestore *and* the claims
/// server-side, but an already-signed-in client keeps its old cached token
/// until something forces a refresh. Firebase never does that
/// automatically. So: watch the live Firestore doc (source of truth,
/// updated by the same write), and if it disagrees with the cached token —
/// role *or* storeIds — force a refresh. Comparing role alone left a gap:
/// a store admin gaining/losing a store without their role itself changing
/// (e.g. a superadmin adding them as a second store's admin) never tripped
/// the old check, so firestore.rules' isStoreAdmin(storeId) kept evaluating
/// against the stale storeIds claim — the client's own storeIdsProvider
/// (fed by this same token) would say a post they own is deletable, but the
/// actual delete request would 403 until the token happened to expire
/// naturally (up to an hour) or they signed out and back in.
final _syncedIdTokenResultProvider = FutureProvider<IdTokenResult?>((
  ref,
) async {
  final user = ref.watch(authStateChangesProvider).value;
  if (user == null) return null;

  final profile = ref.watch(userProfileProvider).value;
  final firestoreRole = profile?['role'] as String? ?? 'user';
  final firestoreStoreIds =
      (profile?['storeIds'] as List<dynamic>?)?.cast<String>().toSet() ??
      const <String>{};

  var result = await user.getIdTokenResult();
  final tokenRole = result.claims?['role'] as String? ?? 'user';
  final tokenStoreIds =
      (result.claims?['storeIds'] as List<dynamic>?)?.cast<String>().toSet() ??
      const <String>{};

  // Set.== is reference equality in Dart, not content equality — comparing
  // these two freshly-built sets directly would always read as "different"
  // and force a refresh on every single call. Length + containsAll is the
  // actual value comparison.
  final storeIdsMatch =
      firestoreStoreIds.length == tokenStoreIds.length &&
      firestoreStoreIds.containsAll(tokenStoreIds);
  if (firestoreRole != tokenRole || !storeIdsMatch) {
    result = await user.getIdTokenResult(true);
  }
  return result;
});

final appRoleProvider = FutureProvider<AppRole>((ref) async {
  final result = await ref.watch(_syncedIdTokenResultProvider.future);
  if (result == null) return AppRole.unauthenticated;

  switch (result.claims?['role']) {
    case 'admin':
      return AppRole.admin;
    case 'superadmin':
      return AppRole.superadmin;
    default:
      return AppRole.user;
  }
});

/// Store ids an admin manages, from their custom claims. Empty for non-admins.
final storeIdsProvider = FutureProvider<List<String>>((ref) async {
  final result = await ref.watch(_syncedIdTokenResultProvider.future);
  if (result == null) return [];

  final storeIds = result.claims?['storeIds'] as List<dynamic>?;
  return storeIds?.cast<String>() ?? [];
});
