import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api_client.dart';
import '../../core/image_crop.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../core/upload_progress.dart';
import '../../services/posts_service.dart';
import '../feed/feed_providers.dart';
import '../reels/reels_screen.dart';
import '../store_profile/store_profile_providers.dart';

enum _FrameMode { fill, fit }

/// Caption + publish step for pre-picked file(s) — reached only from
/// AddContentSheet, which already decided the type ('image' | 'carousel' |
/// 'reel') and did the initial picking/cropping.
///
/// For images, [originalFiles] (the un-cropped sources, one per entry in
/// [files]) enables Instagram's Fill/Fit toggle: Fill re-runs the pan/zoom
/// crop UI on every photo one at a time, Fit letterboxes each original onto
/// a square canvas instead of cropping it.
class PostComposerScreen extends ConsumerStatefulWidget {
  const PostComposerScreen({
    super.key,
    required this.storeId,
    required this.type,
    required this.files,
    this.originalFiles,
  });

  final String storeId;
  final String type;
  final List<XFile> files;
  final List<XFile>? originalFiles;

  @override
  ConsumerState<PostComposerScreen> createState() => _PostComposerScreenState();
}

class _PostComposerScreenState extends ConsumerState<PostComposerScreen> {
  final _captionController = TextEditingController();
  final _priceController = TextEditingController();
  bool _submitting = false;
  bool _reframing = false;

  /// One byte-weighted percentage for the WHOLE publish — every photo of a
  /// carousel, or a reel's video plus its generated thumbnail (see
  /// PostsService.createPost). Null until the first chunk goes out.
  UploadProgress? _progress;
  int _page = 0;
  _FrameMode _mode = _FrameMode.fill;
  late List<XFile> _displayFiles = List.of(widget.files);

  @override
  void dispose() {
    _captionController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  Future<void> _setMode(_FrameMode mode) async {
    final originals = widget.originalFiles;
    if (mode == _mode || originals == null || _reframing) return;
    setState(() => _reframing = true);
    try {
      final result = <XFile>[];
      if (mode == _FrameMode.fill) {
        // One photo at a time, fully awaited — see add_content_sheet.dart's
        // _pickPost for why this must never turn into a tight loop.
        for (final original in originals) {
          final cropped = await cropSquare(original);
          result.add(cropped ?? original);
        }
      } else {
        for (final original in originals) {
          result.add(await fitSquareWithLetterbox(original));
        }
      }
      setState(() {
        _displayFiles = result;
        _mode = mode;
      });
    } finally {
      if (mounted) setState(() => _reframing = false);
    }
  }

  Future<void> _submit() async {
    final s = ref.read(l10nProvider);
    final priceText = _priceController.text.trim();
    // Optional, not required — but easy to forget, so a confirming nudge
    // rather than a silent gap. "Skip" proceeds with price left null; any
    // other dismissal (back button, tapping outside) also just returns to
    // editing, same as tapping "Go back" explicitly.
    if (priceText.isEmpty) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(s.priceEmptyTitle),
          content: Text(s.priceEmptyBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(s.goBack),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(s.skip),
            ),
          ],
        ),
      );
      if (proceed != true) return;
    }
    // The price dialog is an await: the screen can be gone by the time it
    // closes (Android back with the dialog up pops both).
    if (!mounted) return;

    // Both taken before the upload, and for the same reason the story
    // composer takes them: publishing is a media upload — tens of seconds on
    // a mobile link for a reel — and this screen stays pop-able throughout
    // (the AppBar back button and the Android back gesture are both live).
    // `ref.invalidate` on a defunct State THROWS (riverpod's
    // _assertNotDisposed), and the root messenger is the only surface a
    // confirmation can land on once this screen has gone.
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _submitting = true;
      _progress = null;
    });
    try {
      await ref
          .read(postsServiceProvider)
          .createPost(
            storeId: widget.storeId,
            type: widget.type,
            files: widget.type == 'reel' ? widget.files : _displayFiles,
            caption: _captionController.text.trim(),
            price: priceText.isEmpty ? null : num.tryParse(priceText),
            // `mounted` is the dispose guard: backing out mid-upload leaves
            // the upload running (it is not cancellable) and the callbacks
            // keep arriving — without this they would setState on a defunct
            // State.
            onProgress: (p) {
              if (!mounted) return;
              setState(() => _progress = p);
            },
          );
      // The feed/reels/store-profile grids fetch once with .get() rather than
      // a live listener, so without this a freshly published post is invisible
      // until the next manual pull-to-refresh. globalReelsProvider backs the
      // Reels *tab* (distinct from the store's storeReelsProvider grid), so a
      // published reel needs it too or it never shows on the Reels tab.
      container.invalidate(feedNotifierProvider);
      container.invalidate(globalReelsProvider);
      container.invalidate(storePostsProvider(widget.storeId));
      container.invalidate(storeReelsProvider(widget.storeId));
      if (mounted) Navigator.of(context).pop();
      // Un-gated on `mounted`: the post IS published, so it is confirmed
      // whether or not this screen is still up. Owner requirement — success
      // used to be a silent pop.
      messenger.showSnackBar(SnackBar(content: Text(s.postPublished)));
    } catch (e) {
      // Was `'${s.failedToLoad}: $e'` — the raw exception on screen. The
      // files are still here and the button comes back, so the publish can
      // simply be tapped again; nothing the user picked is lost.
      if (mounted) {
        setState(() {
          _submitting = false;
          _progress = null;
        });
      }
      messenger.showSnackBar(
        SnackBar(content: Text(s.uploadFailed(describeUploadError(s, e)))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(l10nProvider);
    final showFrameToggle =
        widget.type != 'reel' && widget.originalFiles != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.type == 'reel' ? s.postStory : s.newPost),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (widget.type == 'reel')
                  const _ReelPreviewTile()
                else
                  AspectRatio(
                    aspectRatio: 1,
                    child: Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: PageView.builder(
                            itemCount: _displayFiles.length,
                            onPageChanged: (i) => setState(() => _page = i),
                            itemBuilder: (context, i) =>
                                FutureBuilder<Uint8List>(
                                  future: _displayFiles[i].readAsBytes(),
                                  builder: (context, snapshot) =>
                                      snapshot.hasData
                                      ? Image.memory(
                                          snapshot.data!,
                                          fit: BoxFit.cover,
                                        )
                                      : const Center(
                                          child: CircularProgressIndicator(),
                                        ),
                                ),
                          ),
                        ),
                        if (_displayFiles.length > 1)
                          Positioned(
                            top: 12,
                            right: 12,
                            child: _CountBadge(
                              label: '${_page + 1}/${_displayFiles.length}',
                            ),
                          ),
                        if (_reframing)
                          const Positioned.fill(
                            child: ColoredBox(
                              color: Colors.black38,
                              child: Center(
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                if (showFrameToggle) ...[
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _FrameModeChip(
                        label: s.fill,
                        selected: _mode == _FrameMode.fill,
                        onTap: () => _setMode(_FrameMode.fill),
                      ),
                      const SizedBox(width: 12),
                      _FrameModeChip(
                        label: s.fit,
                        selected: _mode == _FrameMode.fit,
                        onTap: () => _setMode(_FrameMode.fit),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                TextField(
                  controller: _captionController,
                  decoration: InputDecoration(labelText: s.caption),
                  maxLines: 3,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _priceController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
                  ],
                  decoration: InputDecoration(
                    labelText: s.price,
                    suffixText: 'TMT',
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // The bar only exists while bytes are moving, and it is one
                // bar for the whole job: a four-photo carousel fills it once,
                // not four times.
                if (_submitting) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _progress?.fraction,
                      minHeight: 4,
                      backgroundColor: AppColors.backgroundCard,
                      color: AppColors.brand,
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.brand,
                    ),
                    // Stays disabled for the whole job — upload AND the POST
                    // that follows it — so a second tap cannot publish twice.
                    onPressed: _submitting ? null : _submit,
                    child: _submitting
                        ? Text(
                            _progress == null
                                ? s.uploadingMedia
                                : s.uploadingPercent(_progress!.percent),
                          )
                        : Text(s.publish),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.overlayAlphaBlack,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        label,
        style: AppTypography.bodySmall.copyWith(color: AppColors.textOnPrimary),
      ),
    );
  }
}

class _FrameModeChip extends StatelessWidget {
  const _FrameModeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.brand : AppColors.backgroundCard,
      shape: StadiumBorder(side: BorderSide(color: AppColors.borderDivider)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Text(
            label,
            style: AppTypography.buttonSmall.copyWith(
              color: selected ? Colors.white : AppColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

class _ReelPreviewTile extends StatelessWidget {
  const _ReelPreviewTile();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 300,
      decoration: BoxDecoration(
        color: AppColors.backgroundPrimary,
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.movie_outlined, size: 48, color: AppColors.textMuted),
    );
  }
}
