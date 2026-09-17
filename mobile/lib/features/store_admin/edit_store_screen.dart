import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api_client.dart';
import '../../core/app_icon.dart';
import '../../core/image_crop.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../core/upload_progress.dart';
import '../../services/posts_service.dart';
import '../store_profile/store_profile_providers.dart';

// Mirrors updateStoreSchema (server/src/stores/routes.ts) field for field:
// `name: trim().min(1).max(120)`, `tagline/address: max(255)`, `phone:
// max(20)`. The server answers a bare 400 INVALID_INPUT that names no field,
// so every one of these is enforced here instead — the name by withholding
// Save and saying why, the other three by capping input.
const _maxNameLength = 120;
const _maxTaglineLength = 255;
const _maxAddressLength = 255;
const _maxPhoneLength = 20;

class EditStoreScreen extends ConsumerStatefulWidget {
  const EditStoreScreen({super.key, required this.storeId});

  final String storeId;

  @override
  ConsumerState<EditStoreScreen> createState() => _EditStoreScreenState();
}

class _EditStoreScreenState extends ConsumerState<EditStoreScreen> {
  final _nameController = TextEditingController();
  final _taglineController = TextEditingController();
  final _addressController = TextEditingController();
  final _phoneController = TextEditingController();
  bool _loaded = false;
  bool _saving = false;
  bool _uploadingAvatar = false;
  UploadProgress? _avatarProgress;
  String? _avatarUrl;

  /// Closed in [dispose] so an upload that outlives the screen (this one is
  /// pop-able while the PUT is in flight) cannot setState on a defunct State.
  UploadProgressAggregator? _avatarJob;

  @override
  void dispose() {
    _avatarJob?.close();
    _nameController.dispose();
    _taglineController.dispose();
    _addressController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _loadFrom(Map<String, dynamic> data) {
    if (_loaded) return;
    _nameController.text = data['name'] as String? ?? '';
    _taglineController.text = data['tagline'] as String? ?? '';
    _addressController.text = data['address'] as String? ?? '';
    _phoneController.text = data['phone'] as String? ?? '';
    _avatarUrl = data['avatarUrl'] as String?;
    _loaded = true;
  }

  Future<void> _pickAvatar() async {
    // Guarded like the upload below, and for the same reason: on a real
    // device these two are what actually fail — image_picker throws a
    // PlatformException when the photo-library permission is denied (iOS
    // photo_access_denied, Android 13+ READ_MEDIA_IMAGES) or an activity
    // result comes back broken, and cropSquare can throw on a corrupt image.
    // Uncaught, that escaped the tap handler as a zone error: the sheet never
    // opened and the store admin was told nothing at all.
    final XFile? image;
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
      if (picked == null) return;
      image = await cropSquare(picked);
    } catch (_) {
      // mediaPickFailed, NOT avatarUploadFailed: nothing was uploaded here —
      // nothing was even picked. Telling an admin who just declined the
      // photo-library prompt that their "photo upload failed" points them at
      // the network instead of at the permission they need to grant. Same
      // string add_story_flow.dart uses for the same failure.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ref.read(l10nProvider).mediaPickFailed)),
        );
      }
      return;
    }
    if (image == null || !mounted) return;
    // The messenger before the await, like _save below: this screen is
    // pop-able while the PUT is in flight, and both outcomes have to be
    // reported even if the admin backed out.
    final messenger = ScaffoldMessenger.of(context);
    final s = ref.read(l10nProvider);
    setState(() {
      _uploadingAvatar = true;
      _avatarProgress = null;
    });
    try {
      final bytes = await image.readAsBytes();
      final job = UploadProgressAggregator(
        totalBytes: bytes.length,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _avatarProgress = p);
        },
      );
      _avatarJob?.close();
      _avatarJob = job;
      final slot = job.addFile(bytes.length);
      final url = await ref
          .read(postsServiceProvider)
          .uploadMedia(
            folder: 'stores',
            bytes: bytes,
            fileExt: 'jpg',
            contentType: 'image/jpeg',
            onProgress: slot.report,
          );
      slot.complete();
      if (mounted) setState(() => _avatarUrl = url);
      // The photo is up but NOT saved yet — Save writes avatarUrl onto the
      // store — so this confirms the upload only.
      messenger.showSnackBar(SnackBar(content: Text(s.photoUploaded)));
    } catch (e) {
      // Was try/finally only — a failed upload just took the spinner away —
      // and then a bare "photo upload failed" with no reason. The picked
      // photo is untouched: tapping the avatar again re-picks and retries.
      messenger.showSnackBar(
        SnackBar(
          content: Text('${s.avatarUploadFailed}: ${describeUploadError(s, e)}'),
        ),
      );
    } finally {
      _avatarJob?.close();
      if (mounted) {
        setState(() {
          _uploadingAvatar = false;
          _avatarProgress = null;
        });
      }
    }
  }

  Future<void> _save() async {
    // Matches _saveName in edit_profile_screen.dart: the disabled button is
    // the first line of defence, this one does not depend on a rebuild having
    // landed before the next pointer event (and never sends the old avatarUrl
    // by racing an upload that is still in flight).
    if (_saving || _uploadingAvatar) return;
    final s = ref.read(l10nProvider);
    // The root messenger, taken before the pop below: the confirmation has
    // to land on the store profile this screen returns to, not on a Scaffold
    // that is on its way out.
    final messenger = ScaffoldMessenger.of(context);
    // The container, for the same reason — and it is not optional. The screen
    // stays pop-able while the PATCH is in flight (only Save is disabled), so
    // an Android back gesture during a slow save is ordinary, and
    // `ref.invalidate` on an unmounted State THROWS a StateError (riverpod's
    // _assertNotDisposed, live in release). That throw landed in the catch
    // below, whose body is gated on `mounted` — so a save that SUCCEEDED
    // refreshed nothing and said nothing. Same fix as the story viewer's
    // _deleteCurrent.
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() => _saving = true);
    try {
      await ref.read(apiClientProvider).patch(
        '/stores/${widget.storeId}',
        body: {
          'name': _nameController.text.trim(),
          'tagline': _taglineController.text.trim(),
          'address': _addressController.text.trim(),
          'phone': _phoneController.text.trim(),
          if (_avatarUrl != null) 'avatarUrl': _avatarUrl,
        },
      );
      // Refresh the store profile the screen came from so the edit shows.
      container.invalidate(storeDocProvider(widget.storeId));
      // The confirmation is NOT gated on `mounted`: the save happened, so the
      // admin must be told whether or not this screen is still up — that is
      // exactly what capturing the root messenger above is for. Only the pop
      // needs a live context (there is nothing left to pop otherwise).
      if (mounted) Navigator.of(context).pop();
      messenger.showSnackBar(SnackBar(content: Text(s.profileSaved)));
    } catch (e) {
      // Was try/finally only: a 400 or a dead network escaped the button
      // callback as an unhandled async error and the screen just sat there.
      // Un-gated on `mounted` for the same reason as the confirmation above —
      // backing out mid-save must not turn a failure into silence.
      messenger.showSnackBar(SnackBar(content: Text(describeApiError(s, e))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  InputDecoration _pillDecoration([String? hint, String? errorText]) =>
      InputDecoration(
    hintText: hint,
    errorText: errorText,
    filled: true,
    fillColor: AppColors.backgroundCard,
    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(28),
      borderSide: BorderSide.none,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(l10nProvider);
    final store = ref.watch(storeDocProvider(widget.storeId)).value;
    return Scaffold(
      backgroundColor: AppColors.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundPrimary,
        title: Text(s.editProfile),
      ),
      body: Builder(
        builder: (context) {
          if (store == null) {
            return const Center(child: CircularProgressIndicator());
          }
          _loadFrom(store);

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Center(
                child: GestureDetector(
                  onTap: _uploadingAvatar ? null : _pickAvatar,
                  child: Stack(
                    children: [
                      CircleAvatar(
                        radius: 44,
                        backgroundColor: AppColors.backgroundCard,
                        backgroundImage: (_avatarUrl?.isNotEmpty ?? false)
                            ? CachedNetworkImageProvider(_avatarUrl!)
                            : null,
                        child: (_avatarUrl?.isNotEmpty ?? false)
                            ? null
                            : AppIcon(
                                'image',
                                color: AppColors.textMuted,
                                size: 32,
                              ),
                      ),
                      if (_uploadingAvatar)
                        Positioned.fill(
                          child: CircleAvatar(
                            backgroundColor: Colors.black38,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                    // Determinate the moment the first chunk
                                    // is acknowledged; indeterminate only in
                                    // the instant before that.
                                    value: _avatarProgress?.fraction,
                                  ),
                                ),
                                if (_avatarProgress != null) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    '${_avatarProgress!.percent}%',
                                    style: AppTypography.caption.copyWith(
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        )
                      else
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: CircleAvatar(
                            radius: 14,
                            backgroundColor: AppColors.brand,
                            child: const AppIcon(
                              'plus',
                              size: 18,
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 28),
              Text(s.storeName, style: AppTypography.label),
              const SizedBox(height: 6),
              // The name is the one field a hard maxLength would be wrong for:
              // it can arrive over-long from an older build or the panel, and
              // silently truncating someone's store name on open is worse than
              // naming the rule. So: no cap, Save withheld, and the reason
              // spelled out under the field — a disabled Save with no
              // explanation is what the review rejected.
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _nameController,
                builder: (context, value, _) => TextField(
                  controller: _nameController,
                  style: AppTypography.bodyMedium,
                  decoration: _pillDecoration(
                    null,
                    value.text.trim().length > _maxNameLength
                        ? s.nameTooLong(_maxNameLength)
                        : null,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(s.shortDescription, style: AppTypography.label),
              const SizedBox(height: 6),
              // The remaining three cap at the server's own limits
              // (updateStoreSchema, server/src/stores/routes.ts: tagline 255,
              // address 255, phone 20) so the client cannot compose a request
              // the server must answer with a 400 that names no field. The
              // tagline used to cap at 120 — half what the server allows.
              TextField(
                controller: _taglineController,
                style: AppTypography.bodyMedium,
                maxLength: _maxTaglineLength,
                maxLines: 3,
                decoration: _pillDecoration(),
              ),
              const SizedBox(height: 16),
              Text(s.address, style: AppTypography.label),
              const SizedBox(height: 6),
              TextField(
                controller: _addressController,
                style: AppTypography.bodyMedium,
                // A formatter, not maxLength: the cap is enforced either way,
                // and this keeps these two pills free of a "12/255" counter
                // the design does not have.
                inputFormatters: [
                  LengthLimitingTextInputFormatter(_maxAddressLength),
                ],
                decoration: _pillDecoration(),
              ),
              const SizedBox(height: 16),
              Text(s.phoneNumber, style: AppTypography.label),
              const SizedBox(height: 6),
              TextField(
                controller: _phoneController,
                style: AppTypography.bodyMedium,
                keyboardType: TextInputType.phone,
                inputFormatters: [
                  LengthLimitingTextInputFormatter(_maxPhoneLength),
                ],
                decoration: _pillDecoration('+993 6X XXXXXX'),
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _nameController,
                  builder: (context, value, _) {
                    final name = value.text.trim();
                    // No Save that can only 400 (empty/over-long name), and
                    // none while the avatar is still uploading — Save would
                    // race the upload and send the old avatarUrl.
                    final canSave =
                        name.isNotEmpty &&
                        name.length <= _maxNameLength &&
                        !_uploadingAvatar &&
                        !_saving;
                    return FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.brand,
                        shape: const StadiumBorder(),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      onPressed: canSave ? _save : null,
                      child: _saving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(s.save),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
