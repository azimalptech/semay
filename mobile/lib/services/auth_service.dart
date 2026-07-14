import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firestore_service.dart';

enum AppRole { unauthenticated, user, admin, superadmin }

final firebaseAuthProvider = Provider<FirebaseAuth>((ref) => FirebaseAuth.instance);

final functionsProvider = Provider<FirebaseFunctions>((ref) => FirebaseFunctions.instance);

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
  AuthService(this._auth, this._functions);

  final FirebaseAuth _auth;
  final FirebaseFunctions _functions;

  Future<void> sendOtp(String phone) async {
    await _functions.httpsCallable('sendOtp').call<void>({'phone': phone});
  }

  /// Returns true if this phone belongs to a brand-new user (route to name entry).
  Future<bool> verifyOtp(String phone, String code) async {
    final result = await _functions
        .httpsCallable('verifyOtp')
        .call<Map<String, dynamic>>({'phone': phone, 'code': code});
    final data = Map<String, dynamic>.from(result.data as Map);
    await _auth.signInWithCustomToken(data['customToken'] as String);
    return data['isNewUser'] as bool? ?? false;
  }

  Future<void> completeProfile(String name) async {
    await _functions.httpsCallable('completeProfile').call<void>({'name': name});
  }

  Future<void> signOut() => _auth.signOut();
}

final authServiceProvider = Provider<AuthService>((ref) {
  return AuthService(ref.watch(firebaseAuthProvider), ref.watch(functionsProvider));
});

final appRoleProvider = FutureProvider<AppRole>((ref) async {
  final user = ref.watch(authStateChangesProvider).value;
  if (user == null) return AppRole.unauthenticated;

  final idTokenResult = await user.getIdTokenResult();
  switch (idTokenResult.claims?['role']) {
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
  final user = ref.watch(authStateChangesProvider).value;
  if (user == null) return [];

  final idTokenResult = await user.getIdTokenResult();
  final storeIds = idTokenResult.claims?['storeIds'] as List<dynamic>?;
  return storeIds?.cast<String>() ?? [];
});
