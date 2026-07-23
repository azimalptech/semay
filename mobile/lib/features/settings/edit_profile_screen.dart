import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../services/auth_service.dart';

enum _PhoneStep { display, enterPhone, enterCode }

const _resendCooldown = Duration(seconds: 60);
const _countryCode = '+993';
const _localDigits = 8;

class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  final _nameController = TextEditingController();
  final _newPhoneController = TextEditingController();
  final _codeController = TextEditingController();
  bool _nameInitialized = false;
  bool _isSavingName = false;

  var _phoneStep = _PhoneStep.display;
  bool _isSubmittingPhone = false;
  String? _phoneError;
  int? _attemptsRemaining;
  String? _devCode;
  DateTime? _lockedUntil;
  DateTime _resendAvailableAt = DateTime.now();
  Timer? _ticker;

  @override
  void dispose() {
    _ticker?.cancel();
    _nameController.dispose();
    _newPhoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  String _originalName = '';

  Future<void> _saveName() async {
    final name = _nameController.text.trim();
    if (name.isEmpty || name == _originalName || _isSavingName) return;
    setState(() => _isSavingName = true);
    try {
      await ref.read(authServiceProvider).completeProfile(name);
      _originalName = name;
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(ref.read(l10nProvider).save)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => _isSavingName = false);
    }
  }

  bool get _isLocked =>
      _lockedUntil != null && _lockedUntil!.isAfter(DateTime.now());
  bool get _canResend =>
      !_isLocked && DateTime.now().isAfter(_resendAvailableAt);

  void _startTicker() {
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  String get _fullNewPhone =>
      '$_countryCode${_newPhoneController.text.trim().replaceAll(' ', '')}';

  Future<void> _sendCodeToNewPhone() async {
    final digits = _newPhoneController.text.trim();
    if (digits.isEmpty || _isSubmittingPhone) return;
    if (digits.length != _localDigits) {
      setState(() => _phoneError = ref.read(l10nProvider).invalidPhoneLength);
      return;
    }
    final phone = _fullNewPhone;
    setState(() {
      _isSubmittingPhone = true;
      _phoneError = null;
    });
    try {
      final devCode = await ref.read(authServiceProvider).sendOtp(phone);
      if (!mounted) return;
      _startTicker();
      setState(() {
        _devCode = devCode;
        _resendAvailableAt = DateTime.now().add(_resendCooldown);
        _phoneStep = _PhoneStep.enterCode;
      });
    } on OtpLockedException catch (e) {
      if (!mounted) return;
      _startTicker();
      setState(() {
        _lockedUntil = e.lockedUntil;
        _resendAvailableAt = e.lockedUntil;
        _phoneStep = _PhoneStep.enterCode;
      });
    } catch (e) {
      if (mounted) setState(() => _phoneError = e.toString());
    } finally {
      if (mounted) setState(() => _isSubmittingPhone = false);
    }
  }

  Future<void> _resendCode() async {
    if (!_canResend || _isSubmittingPhone) return;
    final phone = _fullNewPhone;
    setState(() {
      _isSubmittingPhone = true;
      _phoneError = null;
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
      if (mounted) setState(() => _phoneError = e.toString());
    } finally {
      if (mounted) setState(() => _isSubmittingPhone = false);
    }
  }

  Future<void> _verifyNewPhone() async {
    final code = _codeController.text.trim();
    final phone = _fullNewPhone;
    if (code.isEmpty || _isSubmittingPhone) return;
    setState(() {
      _isSubmittingPhone = true;
      _phoneError = null;
    });
    try {
      await ref.read(authServiceProvider).changePhone(phone, code);
      if (mounted) {
        setState(() {
          _phoneStep = _PhoneStep.display;
          _codeController.clear();
          _newPhoneController.clear();
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(ref.read(l10nProvider).save)));
      }
    } on OtpLockedException catch (e) {
      if (!mounted) return;
      setState(() {
        _lockedUntil = e.lockedUntil;
        _resendAvailableAt = e.lockedUntil;
      });
    } on OtpException catch (e) {
      if (!mounted) return;
      setState(() {
        _phoneError = e.message;
        _attemptsRemaining = e.attemptsRemaining;
      });
    } catch (e) {
      if (mounted) setState(() => _phoneError = e.toString());
    } finally {
      if (mounted) setState(() => _isSubmittingPhone = false);
    }
  }

  void _cancelPhoneChange() {
    setState(() {
      _phoneStep = _PhoneStep.display;
      _phoneError = null;
      _attemptsRemaining = null;
      _devCode = null;
      _lockedUntil = null;
      _newPhoneController.clear();
      _codeController.clear();
    });
  }

  String _formatDuration(Duration d) {
    final total = d.inSeconds.clamp(0, 999999);
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    if (hours > 0) return '${hours}h ${minutes}m';
    return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(l10nProvider);
    final profile = ref.watch(userProfileProvider).value;
    final currentPhone = profile?['phone'] as String? ?? '';
    if (!_nameInitialized) {
      _originalName = profile?['name'] as String? ?? '';
      _nameController.text = _originalName;
      _nameInitialized = true;
    }

    return Scaffold(
      backgroundColor: AppColors.backgroundPrimary,
      appBar: AppBar(title: Text(s.editProfile)),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _nameController,
            builder: (context, value, _) {
              final isDirty =
                  value.text.trim().isNotEmpty &&
                  value.text.trim() != _originalName;
              return FilledButton(
                onPressed: isDirty && !_isSavingName ? _saveName : null,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                child: _isSavingName
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(s.save),
              );
            },
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(s.yourName, style: AppTypography.bodyMediumSemibold),
          const SizedBox(height: 8),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(),
          ),
          const SizedBox(height: 24),
          Text(s.phoneNumber, style: AppTypography.bodyMediumSemibold),
          const SizedBox(height: 8),
          if (_phoneStep == _PhoneStep.display) ...[
            Row(
              children: [
                Expanded(
                  child: Text(currentPhone, style: AppTypography.bodyMedium),
                ),
                TextButton(
                  onPressed: () =>
                      setState(() => _phoneStep = _PhoneStep.enterPhone),
                  child: Text(s.change),
                ),
              ],
            ),
          ] else if (_isLocked) ...[
            Text(
              s.numberLockedTitle,
              style: AppTypography.bodyMediumSemibold.copyWith(
                color: AppColors.error,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              s.lockedTryAgainIn(
                _formatDuration(_lockedUntil!.difference(DateTime.now())),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: _cancelPhoneChange, child: Text(s.cancel)),
          ] else if (_phoneStep == _PhoneStep.enterPhone) ...[
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  const Text(
                    _countryCode,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _newPhoneController,
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
            if (_phoneError != null) ...[
              const SizedBox(height: 8),
              Text(_phoneError!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton(
                  onPressed: _cancelPhoneChange,
                  child: Text(s.cancel),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _isSubmittingPhone ? null : _sendCodeToNewPhone,
                  child: _isSubmittingPhone
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(s.sendCode),
                ),
              ],
            ),
          ] else ...[
            Text(s.codeSentTo(_fullNewPhone)),
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
            const SizedBox(height: 8),
            TextField(
              controller: _codeController,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(counterText: ''),
            ),
            if (_phoneError != null) ...[
              const SizedBox(height: 8),
              Text(_phoneError!, style: const TextStyle(color: Colors.red)),
              if (_attemptsRemaining != null)
                Text(
                  s.attemptsRemaining(_attemptsRemaining!),
                  style: const TextStyle(color: Colors.red),
                ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton(
                  onPressed: _cancelPhoneChange,
                  child: Text(s.cancel),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _canResend && !_isSubmittingPhone
                      ? _resendCode
                      : null,
                  child: Text(
                    _canResend
                        ? s.resendCode
                        : s.resendCodeIn(
                            _resendAvailableAt
                                .difference(DateTime.now())
                                .inSeconds
                                .clamp(0, 60),
                          ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _codeController,
              builder: (context, value, _) {
                final hasCode = value.text.trim().isNotEmpty;
                return FilledButton(
                  onPressed: hasCode && !_isSubmittingPhone
                      ? _verifyNewPhone
                      : null,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: _isSubmittingPhone
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(s.verify),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}
