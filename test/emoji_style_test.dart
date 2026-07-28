import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrick_messenger/screens/chat/emoji_style.dart';

void main() {
  test(
    'plain digits remain normal text while real emoji use emoji styling',
    () {
      final spans = colorEmojiTextSpans(
        'file 234.mp4 👍 1️⃣',
        emojiStyle: const TextStyle(fontFamily: 'Test Emoji Font'),
        parentStyle: const TextStyle(fontFamily: 'Test Text Font'),
      ).cast<TextSpan>();

      expect(spans.map((span) => span.text).join(), 'file 234.mp4 👍 1️⃣');
      for (final span in spans.where(
        (span) => RegExp(r'[0-9]').hasMatch(span.text ?? ''),
      )) {
        if (span.text == '1️⃣') continue;
        expect(span.style?.fontFamily, 'Test Text Font');
      }
      expect(
        spans.singleWhere((span) => span.text == '👍').style?.fontFamily,
        'Test Emoji Font',
      );
      expect(
        spans.singleWhere((span) => span.text == '1️⃣').style?.fontFamily,
        'Test Emoji Font',
      );
    },
  );
}
