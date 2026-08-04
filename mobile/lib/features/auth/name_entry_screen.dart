import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n.dart';
import '../../services/auth_service.dart';

/// Collects the name for a FIRST-TIME signup.
///
/// [pendingPhone]/[pendingCode] are set when we arrived here from the OTP
/// screen's NAME_REQUIRED response: no account exists yet, so submitting
/// finishes the original verify call and the server creates the account and
/// its name in one transaction. When they're null this falls back to updating
/// an already-signed-in account, which is how the router's own
/// empty-name redirect reaches this screen.
class NameEntryScreen extends ConsumerStatefulWidget {
  const NameEntryScreen({super.key, this.pendingPhone, this.pendingCode});

  final String? pendingPhone;
  final String? pendingCode;

  @override
  ConsumerState<NameEntryScreen> createState() => _NameEntryScreenState();
}

class _NameEntryScreenState extends ConsumerState<NameEntryScreen> {
  final _nameController = TextEditingController();
  bool _isSubmitting = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    setState(() {
      _isSubmitting = true;
      _error = null;
    });
    try {
      final phone = widget.pendingPhone;
      final code = widget.pendingCode;
      if (phone != null && code != null) {
        // Signup: completes the verify that returned NAME_REQUIRED. The code
        // was never consumed, so this is the same one-shot login — it signs the
        // user in, and the router takes it from there.
        await ref.read(authServiceProvider).verifyOtp(phone, code, name: name);
      } else {
        // Already signed in — just set the name on the existing account.
        await ref.read(authServiceProvider).completeProfile(name);
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(l10nProvider);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(s.whatsYourName, style: const TextStyle(fontSize: 20)),
              const SizedBox(height: 16),
              TextField(
                controller: _nameController,
                decoration: InputDecoration(hintText: s.yourName),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _isSubmitting ? null : _submit,
                child: _isSubmitting
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(s.continueLabel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
