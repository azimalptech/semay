import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Figma icon assets (Homepage frame 195:4299) bundled under
/// `assets/icons/` — see `pubspec.yaml`. Renders with an optional tint
/// override for selected/unselected states (e.g. bottom nav, liked heart).
class AppIcon extends StatelessWidget {
  const AppIcon(this.name, {super.key, this.size = 24, this.color});

  final String name;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      'assets/icons/$name.svg',
      width: size,
      height: size,
      colorFilter: color != null ? ColorFilter.mode(color!, BlendMode.srcIn) : null,
    );
  }
}
