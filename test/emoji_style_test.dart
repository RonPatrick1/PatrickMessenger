import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrick_messenger/screens/chat/emoji_style.dart';

Iterable<TextSpan> _flattenTextSpans(InlineSpan span) sync* {
  if (span is! TextSpan) return;

  yield span;

  for (final child in span.children ?? const <InlineSpan>[]) {
    yield* _flattenTextSpans(child);
  }
}

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

  test('detects supported links and trims sentence punctuation', () {
    final links = messageLinks(
      'A https://one.example/a, '
      'B http://two.example. '
      'C www.three.example! '
      'D four.example/path?q=1.',
    );

    expect(links.map((link) => link.text), [
      'https://one.example/a',
      'http://two.example',
      'www.three.example',
      'four.example/path?q=1',
    ]);

    expect(links.map((link) => link.uri.toString()), [
      'https://one.example/a',
      'http://two.example',
      'https://www.three.example',
      'https://four.example/path?q=1',
    ]);
  });

  test('does not match emails or common filename extensions', () {
    expect(
      messageLinks(
        'person@example.com file.mp4 archive.7z archive.zip photo.jpg report.pdf',
      ),
      isEmpty,
    );
  });

  test('explicit URL markers override filename-extension filtering', () {
    final links = messageLinks('https://photo.jpg www.report.pdf');

    expect(links.map((link) => link.text), [
      'https://photo.jpg',
      'www.report.pdf',
    ]);
  });

  test('keeps balanced closing punctuation inside URLs', () {
    final links = messageLinks(
      'See https://example.com/a_(b) and example.com/path[1].',
    );

    expect(links.map((link) => link.text), [
      'https://example.com/a_(b)',
      'example.com/path[1]',
    ]);
  });

  testWidgets(
    'selectable link remains blue and opens the normalized external URL',
    (tester) async {
      Uri? launched;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ColorEmojiText(
              'Open 👍 example.com now',
              selectable: true,
              linkLauncher: (uri) async {
                launched = uri;
                return true;
              },
            ),
          ),
        ),
      );

      final selectable = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );

      final spans = _flattenTextSpans(selectable.textSpan!).toList();

      final linkSpan = spans.singleWhere((span) => span.text == 'example.com');

      expect(linkSpan.style?.color, Colors.blue);
      expect(linkSpan.style?.decoration, TextDecoration.underline);
      expect(linkSpan.mouseCursor, SystemMouseCursors.click);
      expect(linkSpan.recognizer, isA<TapGestureRecognizer>());

      (linkSpan.recognizer! as TapGestureRecognizer).onTap!();
      await tester.pump();

      expect(launched, Uri.parse('https://example.com'));
    },
  );
}
