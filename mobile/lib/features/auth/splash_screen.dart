import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Shown only for the brief window while Firebase Auth checks for a
/// persisted session (authStateChangesProvider's first, async emission) —
/// see router.dart's redirect logic. Without this, an already-signed-in
/// user's cold start flashed PhoneEntryScreen for a frame before bouncing
/// straight back out of it.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundPrimary,
      body: const Center(
        child: Image(image: AssetImage('assets/logo.png'), height: 120),
      ),
    );
  }
}
