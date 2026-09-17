import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import '../../core/api_client.dart';
import '../../core/app_icon.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../core/upload_progress.dart';
import '../../services/stories_service.dart';
import '../shared/story_bar_provider.dart';
import '../story_viewer/story_providers.dart';

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
  final messenger = ScaffoldMessenger.of(sheetContext);
  final s = ref.read(l10nProvider);
  final picker = ImagePicker();

  // Guarded for the same reason the store avatar picker is (see
  // edit_store_screen.dart _pickAvatar): image_picker throws a
  // PlatformException when the camera/photo permission is denied (iOS
  // photo_access_denied, Android 13+ READ_MEDIA_IMAGES) or an activity result
  // comes back broken. Called straight from the sheet's onTap, so uncaught it
  // left the handler as a zone error — the sheet just sat there, nothing
  // opened, and the store owner was told nothing at all.
  List<XFile> files = const [];
  try {
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
  } catch (e) {
    debugPrint('story: media pick failed: $e');
    messenger.showSnackBar(SnackBar(content: Text(s.mediaPickFailed)));
    return;
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

  /// One byte-weighted percentage across every file in this publish — not a
  /// bar that restarts at each story.
  UploadProgress? _progress;

  /// The files still to publish. A publish that fails partway REMOVES the
  /// ones that already landed, so tapping publish again sends only the rest
  /// instead of duplicating what is already on the ring — previously a
  /// failure on file 3 of 5 left the screen offering to publish all five
  /// again.
  late List<XFile> _files = List.of(widget.files);
  late List<String> _mediaTypes = List.of(widget.mediaTypes);

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _publish() async {
    if (_publishing) return;
    final s = ref.read(l10nProvider);
    // Both captured before the upload: publishing a story is a media upload —
    // seconds on a mobile link — and the screen stays pop-able throughout. On
    // a defunct State `ref.invalidate` THROWS (riverpod's _assertNotDisposed),
    // which the catch below then swallowed, so the two invalidates never ran:
    // the story WAS published but the home ring bar and the store-profile ring
    // kept showing "no story" until a pull-to-refresh or the next resume.
    // There is no realtime event for stories; these two are the only liveness
    // path a publish has.
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    final files = List.of(_files);
    final mediaTypes = List.of(_mediaTypes);
    // Synchronously, before ANY await: the button has to be dead from the
    // first frame after the tap. Measuring the files below is itself an await
    // (a platform call), and a screen popped during it came back to a
    // setState on a defunct State.
    setState(() {
      _publishing = true;
      _progress = null;
    });
    var published = 0;
    try {
      // Sizes up front — the aggregate percentage has to know the whole job
      // before the first byte goes out. A file whose length can't be read is
      // weighted 0 and simply doesn't move the bar.
      final sizes = <int>[];
      for (final file in files) {
        try {
          sizes.add(await file.length());
        } catch (_) {
          sizes.add(0);
        }
      }
      final job = UploadProgressAggregator(
        totalBytes: sizes.fold<int>(0, (a, b) => a + b),
        // The screen is pop-able throughout, so the callback must be inert
        // once the State is gone (a setState on a defunct State is the
        // classic crash here).
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _progress = p);
        },
      );
      final service = ref.read(storiesServiceProvider);
      // Sequential, not parallel — createStory's createdAt is the client
      // clock at call time (see stories_service.dart), so each awaited call
      // naturally lands after the previous one, keeping playback order
      // matched to the order they were selected/previewed in.
      for (var i = 0; i < files.length; i++) {
        final slot = job.addFile(sizes[i]);
        await service.createStory(
          storeId: widget.storeId,
          mediaFile: files[i],
          mediaType: mediaTypes[i],
          onProgress: slot.report,
        );
        slot.complete();
        published++;
      }
      // The story bar (home ring row) and the store's own story viewer fetch
      // once with .get(), not a live listener — without invalidating them a
      // freshly published story is invisible until the next manual refresh.
      container.invalidate(storyBarProvider);
      container.invalidate(storeStoriesProvider(widget.storeId));
      if (mounted) Navigator.of(context).pop();
      // Un-gated on `mounted`, like every other outcome here: the stories are
      // live, so the publish is confirmed whether or not this screen is still
      // up. It used to pop in silence.
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            files.length > 1 ? s.storiesPublished(published) : s.storyPublished,
          ),
        ),
      );
    } catch (e) {
      // Was `'${s.failedToLoad}: $e'` — the raw exception, so a failed publish
      // read "Ýüklenmedi: ApiException(400, INVALID_INPUT)". describeApiError
      // is the same helper the three other screens in this pass use.
      // A publish that failed on file 3 of 5 still put two stories live —
      // refreshed through the container, so it happens whether or not this
      // screen survived the wait.
      if (published > 0) {
        container.invalidate(storyBarProvider);
        container.invalidate(storeStoriesProvider(widget.storeId));
      }
      if (mounted) {
        setState(() {
          _publishing = false;
          _progress = null;
          // Whatever already went up is gone from the retry set (and from the
          // pager) — publishing again must not post it twice.
          _files = files.sublist(published);
          _mediaTypes = mediaTypes.sublist(published);
          _page = _page.clamp(0, _files.isEmpty ? 0 : _files.length - 1);
        });
        if (_files.isEmpty) Navigator.of(context).pop();
      }
      messenger.showSnackBar(
        SnackBar(content: Text(s.uploadFailed(describeUploadError(s, e)))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(l10nProvider);
    final multiple = _files.length > 1;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          PageView.builder(
            controller: _pageController,
            itemCount: _files.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (context, i) => _StoryPreviewPage(
              file: _files[i],
              mediaType: _mediaTypes[i],
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
                  for (var i = 0; i < _files.length; i++)
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_publishing) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _progress?.fraction,
                      minHeight: 4,
                      backgroundColor: Colors.white24,
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
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    // Disabled for the whole job, not just the first file.
                    onPressed: _publishing ? null : _publish,
                    child: _publishing
                        ? Text(
                            _progress == null
                                ? s.uploadingMedia
                                : s.uploadingPercent(_progress!.percent),
                          )
                        : Text(
                            multiple
                                ? '${s.publish} (${_files.length})'
                                : s.publish,
                          ),
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
