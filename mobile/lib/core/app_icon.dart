import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Figma icon assets (Homepage frame 195:4299) bundled under
/// `assets/icons/` — see `pubspec.yaml`. Renders with an optional tint
/// override for selected/unselected states (e.g. bottom nav, liked heart).
///
/// [size]/[color] default to null (not a fixed 24/asset-native-color) and
/// fall back to the ambient [IconTheme] — same contract `Icon` itself
/// honors — so this can freely stand in for a plain `Icon(Icons.xxx)` inside
/// something that sizes/tints via `IconTheme.merge` (e.g. settings_screen's
/// tile rows, which mix Material icons and AppIcon in the same leading slot)
/// without every call site having to repeat size/color explicitly.
class AppIcon extends StatelessWidget {
  const AppIcon(this.name, {super.key, this.size, this.color});

  final String name;
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final resolvedSize = size ?? iconTheme.size ?? 24;
    final resolvedColor = color ?? iconTheme.color;
    return SvgPicture.asset(
      'assets/icons/$name.svg',
      width: resolvedSize,
      height: resolvedSize,
      colorFilter: resolvedColor != null
          ? ColorFilter.mode(resolvedColor, BlendMode.srcIn)
          : null,
    );
  }
}
