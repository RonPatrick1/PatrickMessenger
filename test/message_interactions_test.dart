import 'package:flutter_test/flutter_test.dart';
import 'package:patrick_messenger/screens/chat/message_interactions.dart';

void main() {
  test('extracts only a leading Liam question', () {
    expect(extractLiamQuestion('  LIAM: What happened? '), 'What happened?');
    expect(extractLiamQuestion('Liam:'), '');
    expect(extractLiamQuestion('Hello Liam: no'), isNull);
  });

  group('reactionKeyFromContent', () {
    test('extracts a Matrix reaction emoji', () {
      expect(
        reactionKeyFromContent({
          'm.relates_to': {
            'rel_type': 'm.annotation',
            'event_id': r'$event',
            'key': '👍',
          },
        }),
        '👍',
      );
    });

    test('rejects malformed relationships', () {
      expect(reactionKeyFromContent(const {}), isNull);
      expect(
        reactionKeyFromContent({
          'm.relates_to': {'key': ''},
        }),
        isNull,
      );
    });
  });

  test('animated GIF detection ignores filename case', () {
    expect(isAnimatedGifName('reaction.GIF'), isTrue);
    expect(isAnimatedGifName('picture.jpeg'), isFalse);
  });

  test('recognizes new Liam answer events and strips the text heading', () {
    const content = {
      'msgtype': 'm.text',
      'body': 'Liam:\nA useful answer.',
      liamEventContentKey: true,
    };
    final body = content['body']! as String;

    expect(isLiamAnswerContent(content, body), isTrue);
    expect(visibleLiamAnswerContent(content, body), 'A useful answer.');
  });

  test('repairs legacy quoted Liam answers with escaped newlines', () {
    const content = {
      'msgtype': 'm.text',
      'body': r'Liam: "Liam:\nI am here to help."',
      liamEventContentKey: true,
    };

    expect(
      visibleLiamAnswerContent(content, content['body']! as String),
      'I am here to help.',
    );
  });

  group('isLiamChatterContent', () {
    test('recognizes a Liam question from anyone', () {
      expect(isLiamChatterContent(const {}, 'Liam: what time is it?'), isTrue);
    });

    test('recognizes a Liam answer', () {
      expect(
        isLiamChatterContent({liamEventContentKey: true}, 'The answer.'),
        isTrue,
      );
    });

    test('ignores ordinary conversation', () {
      expect(isLiamChatterContent(const {}, 'See you at 6.'), isFalse);
    });
  });

  group('typingIndicatorLabel', () {
    test('shows Liam as thinking when Liam is the only typer', () {
      expect(
        typingIndicatorLabel(otherTypingNames: const [], liamTyping: true),
        'Liam is thinking...',
      );
    });

    test('names a single other typer', () {
      expect(
        typingIndicatorLabel(
          otherTypingNames: const ['Alice Smith'],
          liamTyping: false,
        ),
        'Alice Smith is typing...',
      );
    });

    test('joins two typers with and', () {
      expect(
        typingIndicatorLabel(
          otherTypingNames: const ['Alice Smith', 'Bob Jones'],
          liamTyping: false,
        ),
        'Alice Smith and Bob Jones are typing...',
      );
    });

    test('falls back to a generic label for three or more', () {
      expect(
        typingIndicatorLabel(
          otherTypingNames: const ['Alice Smith', 'Bob Jones'],
          liamTyping: true,
        ),
        'Several people are typing...',
      );
    });

    test('returns nothing when no one is typing', () {
      expect(
        typingIndicatorLabel(otherTypingNames: const [], liamTyping: false),
        '',
      );
    });
  });
}
