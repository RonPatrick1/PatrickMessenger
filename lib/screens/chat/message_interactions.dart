import 'dart:convert';

import 'package:matrix/matrix.dart';

const liamEventContentKey = 'com.patricklamphier.patrick_messenger.liam_answer';
const liamLeaveCommand = 'Liam: leave this conversation';

String? extractLiamQuestion(String message) {
  final match = RegExp(
    r'^\s*liam\s*:\s*(.*)$',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(message);
  return match?.group(1)?.trim();
}

bool isTextMessage(Event event) {
  return Event.textOnlyMessageTypes.contains(event.messageType);
}

String visibleMessageBody(Event event) {
  return event.calcUnlocalizedBody(
    hideReply: true,
    hideEdit: true,
    plaintextBody: true,
  );
}

bool isLiamAnswer(Event event) {
  return isLiamAnswerContent(event.content, visibleMessageBody(event));
}

bool isLiamAnswerContent(Map<String, dynamic> content, String body) {
  if (content[liamEventContentKey] == true) return true;
  return RegExp(
    r'^\s*🤖\uFE0F?\s*Liam\s*:',
    caseSensitive: false,
  ).hasMatch(body);
}

String visibleLiamAnswer(Event event) {
  return visibleLiamAnswerContent(event.content, visibleMessageBody(event));
}

String visibleLiamAnswerContent(Map<String, dynamic> content, String body) {
  var answer = body.trim();
  final headings = <RegExp>[
    RegExp(r'^\s*Liam\s*:\s*', caseSensitive: false),
    RegExp(r'^\s*🤖\uFE0F?\s*Liam\s*:\s*', caseSensitive: false),
  ];

  // Repair legacy replies where Ollama's answer was stored as a quoted JSON
  // string with escaped newlines, sometimes behind more than one Liam prefix.
  for (var attempt = 0; attempt < 4; attempt++) {
    final before = answer;
    try {
      final decoded = jsonDecode(answer);
      if (decoded is String) answer = decoded.trim();
    } on FormatException {
      // Ordinary answer text is not JSON and needs no decoding.
    }
    for (final heading in headings) {
      answer = answer.replaceFirst(heading, '').trim();
    }
    if (answer == before) break;
  }
  return answer;
}

String? reactionKeyFromContent(Map<String, dynamic> content) {
  final relationship = content['m.relates_to'];
  if (relationship is! Map) return null;
  final key = relationship['key'];
  return key is String && key.isNotEmpty ? key : null;
}

bool isAnimatedGifName(String name) => name.toLowerCase().endsWith('.gif');

/// Whether an event is a Liam question (sent by anyone, addressed to Liam)
/// or a Liam answer, for the "hide Liam chatter" preference.
bool isLiamChatterEvent(Event event) {
  return isLiamChatterContent(event.content, visibleMessageBody(event));
}

bool isLiamChatterContent(Map<String, dynamic> content, String body) {
  return isLiamAnswerContent(content, body) || extractLiamQuestion(body) != null;
}

String typingIndicatorLabel({
  required List<String> otherTypingNames,
  required bool liamTyping,
}) {
  if (otherTypingNames.isEmpty && liamTyping) return 'Liam is thinking...';
  final names = liamTyping ? [...otherTypingNames, 'Liam'] : otherTypingNames;
  if (names.isEmpty) return '';
  if (names.length == 1) return '${names.first} is typing...';
  if (names.length == 2) return '${names[0]} and ${names[1]} are typing...';
  return 'Several people are typing...';
}

class ReactionGroup {
  final String emoji;
  final List<Event> events;
  final bool reactedByMe;

  const ReactionGroup({
    required this.emoji,
    required this.events,
    required this.reactedByMe,
  });

  int get count => events.length;
}

List<ReactionGroup> groupedReactions(
  Event event,
  Timeline timeline,
  String? ownUserId,
) {
  final groups = <String, List<Event>>{};
  for (final reaction in event.aggregatedEvents(
    timeline,
    RelationshipTypes.reaction,
  )) {
    if (reaction.redacted) continue;
    final key = reactionKeyFromContent(reaction.content);
    if (key == null) continue;
    (groups[key] ??= <Event>[]).add(reaction);
  }

  final result = groups.entries
      .map(
        (entry) => ReactionGroup(
          emoji: entry.key,
          events: entry.value,
          reactedByMe: entry.value.any(
            (reaction) => reaction.senderId == ownUserId,
          ),
        ),
      )
      .toList();
  result.sort((a, b) => a.emoji.compareTo(b.emoji));
  return result;
}
