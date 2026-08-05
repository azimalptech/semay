import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../services/auth_service.dart';
import '../shared/widgets/error_state_view.dart';

/// Shown while the persisted session is being resolved and the signed-in user's
/// profile is being fetched — see router.dart's redirect logic. Without it, an
/// already-signed-in user's cold start flashed PhoneEntryScreen for a frame
/// before bouncing straight back out of it.
///
/// It also owns the FAILURE case. The router deliberately holds position here
/// when /users/me errors, because treating a failed fetch as "this user has no
/// name" used to redirect returning users to the name-entry screen. Holding
/// position fixed that, but left the app sitting on the logo indefinitely with
/// no explanation and no way forward whenever the API was unreachable — which,
/// with a manually-started server and a USB tunnel, is often. So when the
/// profile has actually errored, show the connection error state with a retry
/// rather than an unexplained logo.
class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(authStateChangesProvider);
    final profile = ref.watch(userProfileProvider);

    // Only a signed-in user can have a profile error worth surfacing; a signed
    // -out cold start legitimately has no profile and is routed to /auth/phone.
    final signedIn = session.value != null;
    final failed = signedIn && profile.hasError;

    return Scaffold(
      backgroundColor: AppColors.backgroundPrimary,
      body: failed
          ? ErrorStateView(
              // Re-runs the /users/me fetch. On success the router's redirect
              // fires on the new profile value and moves us off this screen.
              onRetry: () => ref.invalidate(userProfileProvider),
            )
          : const Center(
              child: Image(image: AssetImage('assets/logo.png'), height: 120),
            ),
    );
  }
}
