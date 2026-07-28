import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

final _emojiPickerUtils = EmojiPickerUtils();

bool _isPlainAsciiEmojiCandidate(String value) =>
    value.length == 1 && RegExp(r'[0-9#*]').hasMatch(value);

/// Splits text into normal-font and color-emoji spans.
///
/// Unicode marks ordinary digits, `#`, and `*` as emoji-capable because they
/// can begin keycap sequences. The emoji picker's broad matcher therefore
/// styles those standalone characters as emoji too. Keep them in the normal
/// text span, while still styling complete keycaps such as `1️⃣`.
List<InlineSpan> colorEmojiTextSpans(
  String text, {
  required TextStyle emojiStyle,
  TextStyle? parentStyle,
}) {
  final composedEmojiStyle = (parentStyle ?? const TextStyle())
      .merge(DefaultEmojiTextStyle)
      .merge(emojiStyle);
  final matches = _emojiPickerUtils
      .getEmojiRegex()
      .allMatches(text)
      .where(
        (match) => !_isPlainAsciiEmojiCandidate(
          text.substring(match.start, match.end),
        ),
      );
  final spans = <TextSpan>[];
  var cursor = 0;
  var previousWasEmoji = false;

  for (final match in matches) {
    if (cursor < match.start) {
      spans.add(
        TextSpan(text: text.substring(cursor, match.start), style: parentStyle),
      );
      previousWasEmoji = false;
    }

    final matchedText = text.substring(match.start, match.end);
    if (previousWasEmoji && cursor == match.start) {
      final previous = spans.removeLast();
      spans.add(
        TextSpan(
          text: '${previous.text ?? ''}$matchedText',
          style: composedEmojiStyle,
        ),
      );
    } else {
      spans.add(TextSpan(text: matchedText, style: composedEmojiStyle));
    }
    cursor = match.end;
    previousWasEmoji = true;
  }

  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor), style: parentStyle));
  }
  return spans;
}

TextStyle emojiGlyphStyle({double? fontSize}) => TextStyle(
  fontSize: fontSize,
  fontFamily: defaultTargetPlatform == TargetPlatform.linux
      ? 'Noto Color Emoji'
      : null,
);

class EmojiGlyph extends StatelessWidget {
  final String emoji;
  final double? size;

  const EmojiGlyph(this.emoji, {this.size, super.key});

  @override
  Widget build(BuildContext context) => Text(
    emoji,
    textScaler: const TextScaler.linear(1),
    style: emojiGlyphStyle(fontSize: size),
  );
}

class ReactionLabel extends StatelessWidget {
  final String emoji;
  final int count;

  const ReactionLabel({required this.emoji, required this.count, super.key});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      EmojiGlyph(emoji, size: 17),
      const SizedBox(width: 4),
      Text('$count'),
    ],
  );
}

class ColorEmojiText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final bool selectable;
  final int? maxLines;
  final TextOverflow overflow;

  const ColorEmojiText(
    this.text, {
    this.style,
    this.selectable = false,
    this.maxLines,
    this.overflow = TextOverflow.clip,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final span = TextSpan(
      style: style,
      children: colorEmojiTextSpans(
        text,
        emojiStyle: emojiGlyphStyle(),
        parentStyle: style,
      ),
    );
    if (selectable) {
      return SelectableText.rich(span, maxLines: maxLines);
    }
    return Text.rich(span, maxLines: maxLines, overflow: overflow);
  }
}

class ColorEmojiTextEditingController extends TextEditingController {
  final TextStyle emojiTextStyle;

  ColorEmojiTextEditingController({super.text, required this.emojiTextStyle});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    assert(
      !value.composing.isValid || !withComposing || value.isComposingRangeValid,
    );
    final ignoreComposing = !value.isComposingRangeValid || !withComposing;
    if (ignoreComposing) {
      return TextSpan(
        style: style,
        children: colorEmojiTextSpans(
          text,
          emojiStyle: emojiTextStyle,
          parentStyle: style,
        ),
      );
    }

    final composingStyle =
        style?.merge(const TextStyle(decoration: TextDecoration.underline)) ??
        const TextStyle(decoration: TextDecoration.underline);
    return TextSpan(
      style: style,
      children: [
        TextSpan(
          children: colorEmojiTextSpans(
            value.composing.textBefore(value.text),
            emojiStyle: emojiTextStyle,
            parentStyle: style,
          ),
        ),
        TextSpan(
          children: colorEmojiTextSpans(
            value.composing.textInside(value.text),
            emojiStyle: emojiTextStyle,
            parentStyle: composingStyle,
          ),
        ),
        TextSpan(
          children: colorEmojiTextSpans(
            value.composing.textAfter(value.text),
            emojiStyle: emojiTextStyle,
            parentStyle: style,
          ),
        ),
      ],
    );
  }
}
