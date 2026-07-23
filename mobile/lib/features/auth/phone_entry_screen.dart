import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../services/auth_service.dart';
import 'otp_screen.dart';

class PhoneEntryScreen extends ConsumerStatefulWidget {
  const PhoneEntryScreen({super.key});

  @override
  ConsumerState<PhoneEntryScreen> createState() => _PhoneEntryScreenState();
}

class _PhoneEntryScreenState extends ConsumerState<PhoneEntryScreen> {
  final _phoneController = TextEditingController();
  bool _isSubmitting = false;
  String? _error;

  @override
  void dispose() {
    _phoneController.dispose();
    super.dispose();
  }

  static const _countryCode = '+993';
  static const _localDigits = 8;

  Future<void> _submit() async {
    final digits = _phoneController.text.trim().replaceAll(' ', '');
    if (digits.isEmpty) return;
    if (digits.length != _localDigits) {
      setState(() => _error = ref.read(l10nProvider).invalidPhoneLength);
      return;
    }
    final phone = '$_countryCode$digits';

    setState(() {
      _isSubmitting = true;
      _error = null;
    });
    try {
      final devCode = await ref.read(authServiceProvider).sendOtp(phone);
      if (mounted) {
        ref
            .read(pendingOtpArgsProvider.notifier)
            .set(OtpScreenArgs(phone: phone, devCode: devCode));
        context.push('/auth/otp');
      }
    } on OtpLockedException catch (e) {
      if (mounted) {
        ref
            .read(pendingOtpArgsProvider.notifier)
            .set(
              OtpScreenArgs(phone: phone, initialLockedUntil: e.lockedUntil),
            );
        context.push('/auth/otp');
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(l10nProvider);
    return Scaffold(
      backgroundColor: AppColors.backgroundPrimary,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 48),
              Center(child: Image.asset('assets/logo.png', height: 140)),
              const SizedBox(height: 32),
              Text(
                s.welcomeGreeting,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                s.enterPhoneToStart,
                style: AppTypography.bodyMedium.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 24),
              Container(
                decoration: BoxDecoration(
                  color: AppColors.backgroundCard,
                  borderRadius: BorderRadius.circular(28),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    Text(
                      _countryCode,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _phoneController,
                        keyboardType: TextInputType.phone,
                        autofocus: true,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(_localDigits),
                        ],
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 24),
              Text.rich(
                TextSpan(
                  style: AppTypography.caption.copyWith(
                    color: AppColors.textMuted,
                  ),
                  children: [
                    TextSpan(text: s.privacyPolicyAgreement),
                    TextSpan(
                      text: s.privacyPolicy,
                      style: TextStyle(
                        decoration: TextDecoration.underline,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    TextSpan(text: s.privacyPolicyAgreementSuffix),
                  ],
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 52,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.brand,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(26),
                    ),
                  ),
                  onPressed: _isSubmitting ? null : _submit,
                  child: _isSubmitting
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          s.continueLabel,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
