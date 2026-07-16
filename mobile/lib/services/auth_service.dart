import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firestore_service.dart'; // For firestoreProvider

enum AppRole { unauthenticated, user, admin, superadmin }

final firebaseAuthProvider = Provider<FirebaseAuth>((ref) => FirebaseAuth.instance);

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
  AuthService(this._auth, this._db);

  final FirebaseAuth _auth;
  final FirebaseFirestore _db;

  // TODO: remove this dev bypass. In production, call sendOtp Cloud Function
  // which sends real SMS. For now, just validate the phone format locally.
  Future<void> sendOtp(String phone) async {
    if (!_isValidPhone(phone)) throw Exception('Invalid phone number');
  }

  // TODO: remove this dev bypass. In production, call verifyOtp Cloud Function
  // which validates the OTP code and mints a custom token via the Admin SDK.
  //
  // Firestore rules only allow reading users/{uid} where uid == request.auth.uid
  // (no listing the users collection by phone from the client — that's exactly
  // why phone lookup normally goes through a Cloud Function using the Admin
  // SDK, which bypasses rules). So instead of querying Firestore for an
  // existing uid, we let Firebase Auth's own email/password sign-in resolve
  // it: a phone maps 1:1 to a synthetic "<digits>@dev.semay.local" email, and
  // that account's uid is stable across logins once created. Sign-in first;
  // only fall back to account creation if it doesn't exist yet.
  /// Returns true if this phone belongs to a brand-new user (route to name entry).
  Future<bool> verifyOtp(String phone, String code) async {
    final email = _devEmailFor(phone);
    const password = 'dev-testing-password-123';

    bool isNewUser;
    try {
      await _auth.signInWithEmailAndPassword(email: email, password: password);
      isNewUser = false;
    } on FirebaseAuthException catch (e) {
      if (e.code != 'user-not-found' && e.code != 'invalid-credential') rethrow;
      await _auth.createUserWithEmailAndPassword(email: email, password: password);
      isNewUser = true;
    }

    final uid = _auth.currentUser!.uid;
    // merge:true — self-heals if this account existed in Auth but its
    // Firestore doc is missing (e.g. after an emulator data reset).
    await _db.collection('users').doc(uid).set({
      'phone': phone,
      if (isNewUser) 'name': '',
      if (isNewUser) 'avatarUrl': '',
      if (isNewUser) 'role': 'user',
      if (isNewUser) 'storeIds': [],
      if (isNewUser) 'language': 'tk',
      if (isNewUser) 'fcmTokens': [],
      if (isNewUser) 'createdAt': DateTime.now(),
    }, SetOptions(merge: true));

    return isNewUser;
  }

  String _devEmailFor(String phone) {
    final digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
    return '$digits@dev.semay.local';
  }

  Future<void> completeProfile(String name) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw Exception('Not signed in');
    // merge:true — self-heals if the users/{uid} doc is missing (e.g. a
    // stale on-device auth session pointing at data the emulator no longer has).
    await _db.collection('users').doc(uid).set({'name': name}, SetOptions(merge: true));
  }

  Future<void> signOut() => _auth.signOut();

  bool _isValidPhone(String phone) {
    return phone.length > 6 && phone.startsWith('+993');
  }
}

final authServiceProvider = Provider<AuthService>((ref) {
  return AuthService(ref.watch(firebaseAuthProvider), ref.watch(firestoreProvider));
});

/// Custom claims (role/storeIds) are baked into the ID token at issuance —
/// promoting a user to admin (setStoreAdmin) updates both Firestore *and*
/// the claims server-side, but an already-signed-in client keeps its old
/// cached token until something forces a refresh. Firebase never does that
/// automatically. So: watch the live Firestore doc (source of truth,
/// updated by the same write), and if it disagrees with the cached token,
/// force a refresh — that's what actually makes a promotion take effect
/// without the user having to sign out and back in.
final _syncedIdTokenResultProvider = FutureProvider<IdTokenResult?>((ref) async {
  final user = ref.watch(authStateChangesProvider).value;
  if (user == null) return null;

  final profile = ref.watch(userProfileProvider).value;
  final firestoreRole = profile?['role'] as String? ?? 'user';

  var result = await user.getIdTokenResult();
  final tokenRole = result.claims?['role'] as String? ?? 'user';
  if (firestoreRole != tokenRole) {
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
