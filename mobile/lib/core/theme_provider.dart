import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/auth_service.dart';
import '../services/firestore_service.dart';

/// Persists the same way `language` does — on `users/{uid}.darkMode` — so
/// the preference follows the account across devices/reinstalls instead of
/// living only on this device.
final darkModeProvider = Provider<bool>((ref) {
  return ref.watch(userProfileProvider).value?['darkMode'] as bool? ?? false;
});

Future<void> setDarkMode(WidgetRef ref, bool value) async {
  final user = ref.read(authStateChangesProvider).value;
  if (user == null) return;
  await ref.read(firestoreProvider).collection('users').doc(user.uid).update({
    'darkMode': value,
  });
}
