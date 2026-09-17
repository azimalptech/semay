import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/auth_service.dart';
import 'api_client.dart';

/// Persists the same way `language` does — on `users.darkMode` via
/// PATCH /users/me — so the preference follows the account across devices/
/// reinstalls instead of living only on this device.
final darkModeProvider = Provider<bool>((ref) {
  return ref.watch(userProfileProvider).value?['darkMode'] as bool? ?? false;
});

/// Returns false when the preference could NOT be saved, so the caller can
/// say so. It used to be a plain `Future<void>` called from a Switch's
/// onChanged: offline the ApiException escaped as an unhandled zone error and
/// the switch simply sprang back with nothing said.
Future<bool> setDarkMode(WidgetRef ref, bool value) async {
  final session = ref.read(authStateChangesProvider).value;
  if (session == null) return false;
  try {
    await ref.read(apiClientProvider).patch('/users/me', body: {'darkMode': value});
  } catch (_) {
    return false;
  }
  ref.invalidate(userProfileProvider);
  return true;
}
