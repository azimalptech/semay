import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/l10n.dart';
import '../../../core/theme.dart';

/// Figma "No connection" empty/error state — illustration, title, subtitle,
/// and a retry pill button. Used wherever a Firestore stream errors out
/// (usually a dropped connection during dev/testing), instead of a bare
/// error string.
class ErrorStateView extends ConsumerWidget {
  const ErrorStateView({super.key, required this.onRetry, this.message});

  final VoidCallback onRetry;
  final String? message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(l10nProvider);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SvgPicture.asset(
              'assets/illustrations/no_internet.svg',
              width: 160,
              colorFilter: ColorFilter.mode(
                AppColors.textMuted,
                BlendMode.srcIn,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              s.noConnection,
              style: AppTypography.bodyMediumSemibold,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              message ?? s.checkConnection,
              style: AppTypography.bodySmall.copyWith(
                color: AppColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            Material(
              color: AppColors.brand,
              shape: const StadiumBorder(),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: onRetry,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  child: Text(
                    s.tryAgain,
                    style: AppTypography.buttonSmall.copyWith(
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
