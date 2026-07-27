import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

final _emojiPickerUtils = EmojiPickerUtils();

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
      children: _emojiPickerUtils.setEmojiTextStyle(
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
