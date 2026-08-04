import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../services/auth_service.dart';

/// Set by PhoneEntryScreen right before navigating here, and read directly
/// from this provider rather than passed via GoRouter's `extra` — `extra`
/// only survives the *original* push. The moment verifyOtp succeeds,
/// authStateChangesProvider flips and _RouterRefreshNotifier (router.dart)
/// re-runs `redirect` for this same location, which rebuilds OtpScreen with
/// extra reset to null for that frame — flashing the "phone missing"
/// fallback right at the moment of a successful login, before the redirect's
/// next pass (once role/profile finish loading) navigates away. Sourcing
/// from a provider instead sidesteps that entirely, since it isn't tied to
/// route navigation at all.
class OtpScreenArgs {
  const OtpScreenArgs({
    required this.phone,
    this.devCode,
    this.initialLockedUntil,
  });

  final String phone;
  final String? devCode;
  final DateTime? initialLockedUntil;
}

class _PendingOtpArgsNotifier extends Notifier<OtpScreenArgs?> {
  @override
  OtpScreenArgs? build() => null;

  void set(OtpScreenArgs args) => state = args;
}

final pendingOtpArgsProvider =
    NotifierProvider<_PendingOtpArgsNotifier, OtpScreenArgs?>(
      _PendingOtpArgsNotifier.new,
    );

const _resendCooldown = Duration(seconds: 60);
const _codeLength = 6;

class OtpScreen extends ConsumerStatefulWidget {
  const OtpScreen({super.key});

  @override
  ConsumerState<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends ConsumerState<OtpScreen> {
  final _codeController = TextEditingController();
  bool _isSubmitting = false;
  bool _isResending = false;
  String? _error;
  int? _attemptsRemaining;
  String? _devCode;
  DateTime? _lockedUntil;
  late DateTime _resendAvailableAt;
  Timer? _ticker;
  late final String _phone;

  @override
  void initState() {
    super.initState();
    final args = ref.read(pendingOtpArgsProvider);
    debugPrint('otp_screen: initState read args.phone=${args?.phone}');
    _phone = args?.phone ?? '';
    _devCode = args?.devCode;
    _lockedUntil = args?.initialLockedUntil;
    // A lockout means sendOtp never actually issued a fresh code, so the
    // resend cooldown doesn't apply — let resend be available the moment
    // the lockout itself clears instead of stacking another 60s on top.
    _resendAvailableAt = _lockedUntil ?? DateTime.now().add(_resendCooldown);
    // Countdown displays (both the lockout timer and the resend cooldown)
    // are computed from wall-clock time on every tick, not decremented —
    // same pattern as chat_thread_screen's typing-indicator staleness timer.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _codeController.addListener(() {
      if (_codeController.text.length == _codeLength && !_isSubmitting) {
        _submit(_phone);
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  bool get _isLocked =>
      _lockedUntil != null && _lockedUntil!.isAfter(DateTime.now());
  bool get _canResend =>
      !_isLocked && DateTime.now().isAfter(_resendAvailableAt);

  Future<void> _submit(String phone) async {
    final code = _codeController.text.trim();
    if (code.isEmpty || phone.isEmpty) return;

    setState(() {
      _isSubmitting = true;
      _error = null;
    });
    try {
      // Signs the user in; the router redirect reacts to the resulting auth
      // + profile state and routes to /auth/name or the role's home on its
      // own (via _RouterRefreshNotifier) — no explicit navigation needed
      // here. There is deliberately no '/' route to go() to: that used to
      // be attempted here and left every *returning* user (new users escape
      // by luck, since their empty name forces a redirect to /auth/name
      // first) stranded on a blank "page not found" screen with no way
      // back in short of restarting the app.
      await ref.read(authServiceProvider).verifyOtp(phone, code);
    } on NameRequiredException {
      // First-time signup: the code was correct and is still valid, but the
      // account isn't created until we have a name (the server refuses to make
      // a nameless one). Hand the phone AND code to the name screen, which
      // finishes the same verify call. Nothing is signed in yet, so the router
      // can't route us — this navigation is explicit.
      if (!mounted) return;
      context.push('/auth/name', extra: {'phone': phone, 'code': code});
    } on OtpLockedException catch (e) {
      if (!mounted) return;
      setState(() {
        _lockedUntil = e.lockedUntil;
        _resendAvailableAt = e.lockedUntil;
      });
    } on OtpException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _attemptsRemaining = e.attemptsRemaining;
        _codeController.clear();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Future<void> _resend(String phone) async {
    if (!_canResend || _isResending) return;
    setState(() {
      _isResending = true;
      _error = null;
    });
    try {
      final devCode = await ref.read(authServiceProvider).sendOtp(phone);
      if (!mounted) return;
      setState(() {
        _devCode = devCode;
        _resendAvailableAt = DateTime.now().add(_resendCooldown);
        _attemptsRemaining = null;
      });
    } on OtpLockedException catch (e) {
      if (!mounted) return;
      setState(() {
        _lockedUntil = e.lockedUntil;
        _resendAvailableAt = e.lockedUntil;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isResending = false);
    }
  }

  String _formatDuration(Duration d) {
    final total = d.inSeconds.clamp(0, 999999);
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    if (hours > 0) {
      return '${hours}h ${minutes}m';
    }
    return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(l10nProvider);
    final phone = _phone;
    if (phone.isEmpty) {
      debugPrint(
        'otp_screen: build() showing missingPhoneGoBack fallback (_phone is empty)',
      );
      return Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => context.go('/auth/phone'),
            child: Text(s.missingPhoneGoBack),
          ),
        ),
      );
    }

    if (_isLocked) {
      return Scaffold(
        backgroundColor: AppColors.backgroundPrimary,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_clock_outlined, size: 48),
                const SizedBox(height: 16),
                Text(
                  s.numberLockedTitle,
                  style: const TextStyle(fontSize: 20),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  s.lockedTryAgainIn(
                    _formatDuration(_lockedUntil!.difference(DateTime.now())),
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    final resendWait = _resendAvailableAt.difference(DateTime.now());

    return Scaffold(
      backgroundColor: AppColors.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundPrimary,
        elevation: 0,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                s.verificationTitle,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                s.codeSentToGeneric,
                style: AppTypography.bodyMedium.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              if (_devCode != null) ...[
                const SizedBox(height: 8),
                Text(
                  '${s.devCodeLabel} $_devCode',
                  style: const TextStyle(
                    color: Colors.orange,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
              const SizedBox(height: 32),
              _OtpBoxInput(controller: _codeController, length: _codeLength),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.red)),
                if (_attemptsRemaining != null)
                  Text(
                    s.attemptsRemaining(_attemptsRemaining!),
                    style: const TextStyle(color: Colors.red),
                  ),
              ],
              const SizedBox(height: 24),
              if (_isSubmitting)
                const Center(child: CircularProgressIndicator())
              else
                Center(
                  child: TextButton(
                    onPressed: _canResend && !_isResending
                        ? () => _resend(phone)
                        : null,
                    child: _isResending
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            _canResend
                                ? s.resendCode
                                : s.resendCodeIn(
                                    resendWait.inSeconds.clamp(0, 60),
                                  ),
                          ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Individual boxed digits (Verification mockup) backed by one invisible
/// TextField overlay — keeps all the normal keyboard/focus/paste behavior of
/// a single text field instead of juggling N separate FocusNodes, while
/// still rendering as N boxes that fill in as the user types.
class _OtpBoxInput extends StatelessWidget {
  const _OtpBoxInput({required this.controller, required this.length});

  final TextEditingController controller;
  final int length;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Stack(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(length, (i) {
              return ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (context, value, _) {
                  final char = i < value.text.length ? value.text[i] : '';
                  final isCurrent = i == value.text.length;
                  return Container(
                    width: 44,
                    height: 56,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.backgroundCard,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isCurrent
                            ? AppColors.brand
                            : AppColors.borderDivider,
                        width: isCurrent ? 2 : 1,
                      ),
                    ),
                    child: Text(
                      char,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  );
                },
              );
            }),
          ),
          Positioned.fill(
            child: TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: length,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(color: Colors.transparent),
              cursorColor: Colors.transparent,
              decoration: const InputDecoration(
                counterText: '',
                border: InputBorder.none,
                focusedBorder: InputBorder.none,
                enabledBorder: InputBorder.none,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
