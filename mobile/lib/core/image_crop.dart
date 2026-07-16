import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';

import 'theme.dart';

/// Instagram-style crop step before upload — the user controls pan/zoom
/// instead of the app silently center-cropping to fit a square grid tile.
/// Returns null if the user cancels (caller should drop that file, not
/// upload the un-cropped original).
Future<XFile?> cropSquare(XFile source) async {
  final cropped = await ImageCropper().cropImage(
    sourcePath: source.path,
    aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
    uiSettings: [
      AndroidUiSettings(
        lockAspectRatio: true,
        hideBottomControls: false,
        toolbarColor: AppColors.brand,
        toolbarWidgetColor: AppColors.textOnPrimary,
        activeControlsWidgetColor: AppColors.brand,
      ),
      IOSUiSettings(aspectRatioLockEnabled: true, resetAspectRatioEnabled: false),
    ],
  );
  return cropped == null ? null : XFile(cropped.path);
}

/// Instagram's "Fit" mode: whole image visible, letterboxed onto a square
/// canvas instead of cropped — composited client-side with dart:ui (no
/// native crop UI involved, so nothing to pan; the full frame is shown).
Future<XFile> fitSquareWithLetterbox(XFile source, {Color background = Colors.white}) async {
  final bytes = await source.readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final side = image.width > image.height ? image.width : image.height;
  final sideD = side.toDouble();

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, sideD, sideD));
  canvas.drawRect(Rect.fromLTWH(0, 0, sideD, sideD), Paint()..color = background);
  canvas.drawImage(
    image,
    Offset((side - image.width) / 2, (side - image.height) / 2),
    Paint(),
  );
  final picture = recorder.endRecording();
  final squared = await picture.toImage(side, side);
  final byteData = await squared.toByteData(format: ui.ImageByteFormat.png);
  final pngBytes = byteData!.buffer.asUint8List();

  return XFile.fromData(pngBytes, name: 'fit.png', mimeType: 'image/png');
}
