import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import '../../core/app_icon.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../services/stories_service.dart';

/// Add-story entry point behind the "+" badge on the own-store ring
/// (Figma 223:7107). Options sheet -> capture/pick -> full-screen preview ->
/// publish.
///
/// Capture uses image_picker's camera source: on Android/iOS this opens the
/// system camera (photo or video mode per option); on web it falls back to
/// the browser file picker. An in-app hold-to-record camera like Instagram's
/// needs the `camera` package and a device build — tracked as a follow-up,
/// not silently faked here.
Future<void> showAddStorySheet(
  BuildContext context,
  WidgetRef ref, {
  required String storeId,
}) async {
  final s = ref.read(l10nProvider);

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.backgroundCard,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Text(s.newStory, style: AppTypography.titleLarge),
                const Spacer(),
                IconButton(
                  icon: AppIcon('close', color: AppColors.textPrimary),
                  onPressed: () => Navigator.of(sheetContext).pop(),
                ),
              ],
            ),
          ),
          ListTile(
            leading: Icon(
              Icons.photo_camera_outlined,
              color: AppColors.textPrimary,
            ),
            title: Text(s.takePhoto, style: AppTypography.bodyMedium),
            onTap: () =>
                _pick(sheetContext, ref, storeId, _PickKind.cameraPhoto),
          ),
          ListTile(
            leading: Icon(
              Icons.videocam_outlined,
              color: AppColors.textPrimary,
            ),
            title: Text(s.recordVideo, style: AppTypography.bodyMedium),
            onTap: () =>
                _pick(sheetContext, ref, storeId, _PickKind.cameraVideo),
          ),
          ListTile(
            leading: Icon(
              Icons.photo_library_outlined,
              color: AppColors.textPrimary,
            ),
            title: Text(s.chooseFromGallery, style: AppTypography.bodyMedium),
            onTap: () => _pick(sheetContext, ref, storeId, _PickKind.gallery),
          ),
        ],
      ),
    ),
  );
}

enum _PickKind { cameraPhoto, cameraVideo, gallery }

Future<void> _pick(
  BuildContext sheetContext,
  WidgetRef ref,
  String storeId,
  _PickKind kind,
) async {
  final navigator = Navigator.of(sheetContext);
  final picker = ImagePicker();

  List<XFile> files = const [];
  switch (kind) {
    case _PickKind.cameraPhoto:
      final file = await picker.pickImage(source: ImageSource.camera);
      if (file != null) files = [file];
    case _PickKind.cameraVideo:
      final file = await picker.pickVideo(source: ImageSource.camera);
      if (file != null) files = [file];
    case _PickKind.gallery:
      // pickMultipleMedia (not pickMultiImage) — stories mix photos and
      // videos in the same gallery pick, same as Instagram's own story
      // composer; pickMultiImage only ever returns images.
      files = await picker.pickMultipleMedia();
  }
  if (files.isEmpty || !sheetContext.mounted) return;

  final mediaTypes = [
    for (final file in files)
      kind == _PickKind.cameraVideo || _isVideo(file) ? 'video' : 'image',
  ];

  navigator.pop();
  await navigator.push(
    MaterialPageRoute<void>(
      builder: (context) => StoryPreviewScreen(
        storeId: storeId,
        files: files,
        mediaTypes: mediaTypes,
      ),
    ),
  );
}

bool _isVideo(XFile file) {
  final mime = file.mimeType;
  if (mime != null) return mime.startsWith('video/');
  final name = file.name.toLowerCase();
  return name.endsWith('.mp4') ||
      name.endsWith('.mov') ||
      name.endsWith('.webm');
}

/// See/approve step before publishing — Figma flow: capture -> preview ->
/// publish. A multi-select gallery pick previews as a swipeable sequence
/// (page dots at top, same idea as Instagram's multi-story composer); a
/// single camera capture is just a one-page version of the same screen.
/// Publishing creates one stories/{storyId} doc per file, in order, so they
/// play back as a sequence on the story bar.
class StoryPreviewScreen extends ConsumerStatefulWidget {
  const StoryPreviewScreen({
    super.key,
    required this.storeId,
    required this.files,
    required this.mediaTypes,
  });

  final String storeId;
  final List<XFile> files;
  final List<String> mediaTypes;

  @override
  ConsumerState<StoryPreviewScreen> createState() => _StoryPreviewScreenState();
}

class _StoryPreviewScreenState extends ConsumerState<StoryPreviewScreen> {
  final _pageController = PageController();
  int _page = 0;
  bool _publishing = false;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _publish() async {
    final s = ref.read(l10nProvider);
    setState(() => _publishing = true);
    try {
      final service = ref.read(storiesServiceProvider);
      // Sequential, not parallel — createStory's createdAt is the client
      // clock at call time (see stories_service.dart), so each awaited call
      // naturally lands after the previous one, keeping playback order
      // matched to the order they were selected/previewed in.
      for (var i = 0; i < widget.files.length; i++) {
        await service.createStory(
          storeId: widget.storeId,
          mediaFile: widget.files[i],
          mediaType: widget.mediaTypes[i],
        );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _publishing = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${s.failedToLoad}: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(l10nProvider);
    final multiple = widget.files.length > 1;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          PageView.builder(
            controller: _pageController,
            itemCount: widget.files.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (context, i) => _StoryPreviewPage(
              file: widget.files[i],
              mediaType: widget.mediaTypes[i],
              active: i == _page,
            ),
          ),
          if (multiple)
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 56,
              right: 16,
              child: Row(
                children: [
                  for (var i = 0; i < widget.files.length; i++)
                    Expanded(
                      child: Container(
                        height: 3,
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(
                          color: i <= _page
                              ? Colors.white
                              : Colors.white.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 8,
            child: IconButton(
              icon: const AppIcon('close', color: Colors.white, size: 28),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: MediaQuery.of(context).padding.bottom + 16,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.brand,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _publishing ? null : _publish,
              child: _publishing
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      multiple
                          ? '${s.publish} (${widget.files.length})'
                          : s.publish,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One page of the preview pager — owns its own video controller so only
/// the currently-active page plays, matching every other reel/story player
/// in the app (see ReelPlayerView's isActive convention).
class _StoryPreviewPage extends StatefulWidget {
  const _StoryPreviewPage({
    required this.file,
    required this.mediaType,
    required this.active,
  });

  final XFile file;
  final String mediaType;
  final bool active;

  @override
  State<_StoryPreviewPage> createState() => _StoryPreviewPageState();
}

class _StoryPreviewPageState extends State<_StoryPreviewPage> {
  VideoPlayerController? _video;

  @override
  void initState() {
    super.initState();
    if (widget.mediaType == 'video') {
      // XFile.path is a blob: URL on web and a file path on device —
      // networkUrl handles both through the video_player platform layers.
      _video = VideoPlayerController.networkUrl(Uri.parse(widget.file.path))
        ..setLooping(true)
        ..initialize().then((_) {
          if (!mounted) return;
          setState(() {});
          if (widget.active) _video!.play();
        });
    }
  }

  @override
  void didUpdateWidget(covariant _StoryPreviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active == oldWidget.active) return;
    final video = _video;
    if (video == null || !video.value.isInitialized) return;
    if (widget.active) {
      video.seekTo(Duration.zero);
      video.play();
    } else {
      video.pause();
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.mediaType == 'video') {
      return (_video?.value.isInitialized ?? false)
          ? FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: _video!.value.size.width,
                height: _video!.value.size.height,
                child: VideoPlayer(_video!),
              ),
            )
          : const Center(child: CircularProgressIndicator(color: Colors.white));
    }
    return FutureBuilder(
      future: widget.file.readAsBytes(),
      builder: (context, snapshot) => snapshot.hasData
          ? Image.memory(snapshot.data!, fit: BoxFit.contain)
          : const Center(child: CircularProgressIndicator(color: Colors.white)),
    );
  }
}
