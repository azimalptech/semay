import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

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
Future<void> showAddStorySheet(BuildContext context, WidgetRef ref, {required String storeId}) async {
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
                  icon: const Icon(Icons.close, color: AppColors.textPrimary),
                  onPressed: () => Navigator.of(sheetContext).pop(),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined, color: AppColors.textPrimary),
            title: Text(s.takePhoto, style: AppTypography.bodyMedium),
            onTap: () => _pick(sheetContext, ref, storeId, _PickKind.cameraPhoto),
          ),
          ListTile(
            leading: const Icon(Icons.videocam_outlined, color: AppColors.textPrimary),
            title: Text(s.recordVideo, style: AppTypography.bodyMedium),
            onTap: () => _pick(sheetContext, ref, storeId, _PickKind.cameraVideo),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined, color: AppColors.textPrimary),
            title: Text(s.chooseFromGallery, style: AppTypography.bodyMedium),
            onTap: () => _pick(sheetContext, ref, storeId, _PickKind.gallery),
          ),
        ],
      ),
    ),
  );
}

enum _PickKind { cameraPhoto, cameraVideo, gallery }

Future<void> _pick(BuildContext sheetContext, WidgetRef ref, String storeId, _PickKind kind) async {
  final navigator = Navigator.of(sheetContext);
  final picker = ImagePicker();

  XFile? file;
  String mediaType = 'image';
  switch (kind) {
    case _PickKind.cameraPhoto:
      file = await picker.pickImage(source: ImageSource.camera);
    case _PickKind.cameraVideo:
      file = await picker.pickVideo(source: ImageSource.camera);
      mediaType = 'video';
    case _PickKind.gallery:
      file = await picker.pickMedia();
      if (file != null) mediaType = _isVideo(file) ? 'video' : 'image';
  }
  if (file == null || !sheetContext.mounted) return;

  navigator.pop();
  await navigator.push(MaterialPageRoute<void>(
    builder: (context) => StoryPreviewScreen(storeId: storeId, file: file!, mediaType: mediaType),
  ));
}

bool _isVideo(XFile file) {
  final mime = file.mimeType;
  if (mime != null) return mime.startsWith('video/');
  final name = file.name.toLowerCase();
  return name.endsWith('.mp4') || name.endsWith('.mov') || name.endsWith('.webm');
}

/// See/approve step before publishing — Figma flow: capture -> preview ->
/// publish.
class StoryPreviewScreen extends ConsumerStatefulWidget {
  const StoryPreviewScreen({
    super.key,
    required this.storeId,
    required this.file,
    required this.mediaType,
  });

  final String storeId;
  final XFile file;
  final String mediaType;

  @override
  ConsumerState<StoryPreviewScreen> createState() => _StoryPreviewScreenState();
}

class _StoryPreviewScreenState extends ConsumerState<StoryPreviewScreen> {
  VideoPlayerController? _video;
  bool _publishing = false;

  @override
  void initState() {
    super.initState();
    if (widget.mediaType == 'video') {
      // XFile.path is a blob: URL on web and a file path on device —
      // networkUrl handles both through the video_player platform layers.
      _video = VideoPlayerController.networkUrl(Uri.parse(widget.file.path))
        ..setLooping(true)
        ..initialize().then((_) {
          if (mounted) {
            _video!.play();
            setState(() {});
          }
        });
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  Future<void> _publish() async {
    final s = ref.read(l10nProvider);
    setState(() => _publishing = true);
    try {
      await ref.read(storiesServiceProvider).createStory(
            storeId: widget.storeId,
            mediaFile: widget.file,
            mediaType: widget.mediaType,
          );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _publishing = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${s.failedToLoad}: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(l10nProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (widget.mediaType == 'video')
            (_video?.value.isInitialized ?? false)
                ? FittedBox(
                    fit: BoxFit.contain,
                    child: SizedBox(
                      width: _video!.value.size.width,
                      height: _video!.value.size.height,
                      child: VideoPlayer(_video!),
                    ),
                  )
                : const Center(child: CircularProgressIndicator(color: Colors.white))
          else
            FutureBuilder(
              future: widget.file.readAsBytes(),
              builder: (context, snapshot) => snapshot.hasData
                  ? Image.memory(snapshot.data!, fit: BoxFit.contain)
                  : const Center(child: CircularProgressIndicator(color: Colors.white)),
            ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 8,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 28),
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
                      height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(s.publish),
            ),
          ),
        ],
      ),
    );
  }
}
