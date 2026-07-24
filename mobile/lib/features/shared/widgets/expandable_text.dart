import 'package:flutter/material.dart';

import '../../../core/theme.dart';

/// Instagram-style caption: truncated to [maxLines] with a tappable "…more"
/// appended inline at the exact cutoff point (not a plain ellipsis with no
/// way to read the rest) — tapping it expands to the full text in place.
/// Expanded text ends with a tappable "less" that collapses it back.
///
/// [prefix] (e.g. a store name) always renders in full before [text] and
/// counts toward the same line budget, same as Instagram's
/// "username caption…more" — only [text] itself gets truncated.
class ExpandableText extends StatefulWidget {
  const ExpandableText({
    super.key,
    this.prefix,
    this.prefixStyle,
    required this.text,
    required this.style,
    this.maxLines = 2,
    this.moreLabel = 'more',
    this.lessLabel = 'less',
    this.moreStyle,
  });

  final String? prefix;
  final TextStyle? prefixStyle;
  final String text;
  final TextStyle style;
  final int maxLines;
  final String moreLabel;
  final String lessLabel;
  final TextStyle? moreStyle;

  @override
  State<ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<ExpandableText> {
  bool _expanded = false;

  TextSpan? get _prefixSpan => widget.prefix == null
      ? null
      : TextSpan(
          text: '${widget.prefix} ',
          style: widget.prefixStyle ?? widget.style,
        );

  @override
  Widget build(BuildContext context) {
    // AnimatedSize, not an instant rebuild — expanding/collapsing changes
    // how many lines render, and without this the height jump is a jarring
    // snap instead of a smooth grow/shrink.
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      alignment: Alignment.topLeft,
      child: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final prefixSpan = _prefixSpan;

    final moreStyle =
        widget.moreStyle ??
        widget.style.copyWith(
          color: AppColors.textMuted,
          fontWeight: FontWeight.w600,
        );

    if (_expanded) {
      return GestureDetector(
        onTap: () => setState(() => _expanded = false),
        child: Text.rich(
          TextSpan(
            children: [
              ?prefixSpan,
              TextSpan(text: widget.text, style: widget.style),
              TextSpan(text: ' ${widget.lessLabel}', style: moreStyle),
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final direction = Directionality.of(context);
        final moreSpan = TextSpan(
          text: ' ${widget.moreLabel}',
          style: moreStyle,
        );

        // Does the full text even overflow maxLines at this width? If not,
        // there's nothing to truncate — show it as-is, no "more" affordance.
        final fullPainter = TextPainter(
          text: TextSpan(
            children: [
              ?prefixSpan,
              TextSpan(text: widget.text, style: widget.style),
            ],
          ),
          maxLines: widget.maxLines,
          textDirection: direction,
        )..layout(maxWidth: constraints.maxWidth);

        if (!fullPainter.didExceedMaxLines) {
          return Text.rich(
            TextSpan(
              children: [
                ?prefixSpan,
                TextSpan(text: widget.text, style: widget.style),
              ],
            ),
          );
        }

        // Binary search the longest prefix of `text` such that
        // "<prefix><that many chars>…more" still fits within maxLines — the
        // same approach real caption-truncation implementations use, since
        // Flutter's own `overflow: ellipsis` has no way to reserve room for
        // trailing clickable text at the cut point.
        var low = 0;
        var high = widget.text.length;
        var best = 0;
        while (low <= high) {
          final mid = (low + high) ~/ 2;
          final candidate = TextPainter(
            text: TextSpan(
              children: [
                ?prefixSpan,
                TextSpan(
                  text: '${widget.text.substring(0, mid).trimRight()}…',
                  style: widget.style,
                ),
                moreSpan,
              ],
            ),
            maxLines: widget.maxLines,
            textDirection: direction,
          )..layout(maxWidth: constraints.maxWidth);
          if (candidate.didExceedMaxLines) {
            high = mid - 1;
          } else {
            best = mid;
            low = mid + 1;
          }
        }

        return GestureDetector(
          onTap: () => setState(() => _expanded = true),
          child: Text.rich(
            TextSpan(
              children: [
                ?prefixSpan,
                TextSpan(
                  text: '${widget.text.substring(0, best).trimRight()}…',
                  style: widget.style,
                ),
                moreSpan,
              ],
            ),
          ),
        );
      },
    );
  }
}
