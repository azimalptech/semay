import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/image_crop.dart';
import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../story_composer/add_story_flow.dart';
import 'post_composer_screen.dart';

/// "+" FAB entry point on the admin's own Store Detail page (Figma "Add"
/// sheet): Story / Post / Reel, each a distinct flow rather than one form
/// with a mode toggle.
Future<void> showAddContentSheet(
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
                Text(s.addContent, style: AppTypography.titleLarge),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, color: AppColors.textPrimary),
                  onPressed: () => Navigator.of(sheetContext).pop(),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.auto_stories_outlined, color: AppColors.textPrimary),
            title: Text(s.story, style: AppTypography.bodyMedium),
            onTap: () {
              Navigator.of(sheetContext).pop();
              showAddStorySheet(context, ref, storeId: storeId);
            },
          ),
          const _DashedDivider(),
          ListTile(
            leading: const Icon(Icons.grid_view_outlined, color: AppColors.textPrimary),
            title: Text(s.post, style: AppTypography.bodyMedium),
            onTap: () => _pickPost(sheetContext, context, ref, storeId),
          ),
          const _DashedDivider(),
          ListTile(
            leading: const Icon(Icons.play_circle_outline, color: AppColors.textPrimary),
            title: Text(s.reel, style: AppTypography.bodyMedium),
            onTap: () => _pickReel(sheetContext, context, ref, storeId),
          ),
        ],
      ),
    ),
  );
}

// Multi-select, cropped one photo at a time — an earlier version crashed
// here ("Reply already submitted" from image_cropper's Android plugin), but
// that turned out to be caused by UCropActivity missing from
// AndroidManifest.xml, not by looping cropImage() itself. Each call below is
// still fully awaited before the next starts.
Future<void> _pickPost(
  BuildContext sheetContext,
  BuildContext hostContext,
  WidgetRef ref,
  String storeId,
) async {
  final picked = await ImagePicker().pickMultiImage();
  if (picked.isEmpty || !sheetContext.mounted) return;

  // Kept parallel to `cropped` — if the user cancels a crop mid-way, that
  // photo is dropped from both lists so they stay aligned for Fill/Fit
  // re-processing later.
  final cropped = <XFile>[];
  final originals = <XFile>[];
  for (final image in picked) {
    final result = await cropSquare(image);
    if (result != null) {
      cropped.add(result);
      originals.add(image);
    }
  }
  if (cropped.isEmpty || !sheetContext.mounted) return;

  Navigator.of(sheetContext).pop();
  await Navigator.of(hostContext).push(MaterialPageRoute<void>(
    builder: (context) => PostComposerScreen(
      storeId: storeId,
      type: cropped.length > 1 ? 'carousel' : 'image',
      files: cropped,
      originalFiles: originals,
    ),
  ));
}

Future<void> _pickReel(
  BuildContext sheetContext,
  BuildContext hostContext,
  WidgetRef ref,
  String storeId,
) async {
  final video = await ImagePicker().pickVideo(source: ImageSource.gallery);
  if (video == null || !sheetContext.mounted) return;

  Navigator.of(sheetContext).pop();
  await Navigator.of(hostContext).push(MaterialPageRoute<void>(
    builder: (context) => PostComposerScreen(storeId: storeId, type: 'reel', files: [video]),
  ));
}

class _DashedDivider extends StatelessWidget {
  const _DashedDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: CustomPaint(
        size: const Size(double.infinity, 1),
        painter: _DashPainter(),
      ),
    );
  }
}

class _DashPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.borderDivider
      ..strokeWidth = 1;
    const dashWidth = 6.0;
    const gap = 4.0;
    var x = 0.0;
    while (x < size.width) {
      canvas.drawLine(Offset(x, 0), Offset(x + dashWidth, 0), paint);
      x += dashWidth + gap;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
