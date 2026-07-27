import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/auth_service.dart';
import 'api_client.dart';

/// Persists the same way `language` does — on `users.darkMode` via
/// PATCH /users/me — so the preference follows the account across devices/
/// reinstalls instead of living only on this device.
final darkModeProvider = Provider<bool>((ref) {
  return ref.watch(userProfileProvider).value?['darkMode'] as bool? ?? false;
});

Future<void> setDarkMode(WidgetRef ref, bool value) async {
  final session = ref.read(authStateChangesProvider).value;
  if (session == null) return;
  await ref.read(apiClientProvider).patch('/users/me', body: {'darkMode': value});
  ref.invalidate(userProfileProvider);
}
