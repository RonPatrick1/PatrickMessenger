import 'dart:async';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

final _emojiPickerUtils = EmojiPickerUtils();

bool _isPlainAsciiEmojiCandidate(String value) =>
    value.length == 1 && RegExp(r'[0-9#*]').hasMatch(value);

typedef MessageLinkLauncher = Future<bool> Function(Uri uri);

@immutable
class MessageLinkMatch {
  final int start;
  final int end;
  final String text;
  final Uri uri;

  const MessageLinkMatch({
    required this.start,
    required this.end,
    required this.text,
    required this.uri,
  });
}

final RegExp _messageLinkPattern = RegExp(
  r'(^|[^A-Za-z0-9_@])'
  r'((?:(?:https?://|www\.)[^\s<]+|'
  r'(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+'
  r'[A-Za-z]{2,63}(?::\d{1,5})?(?:[/?#][^\s<]*)?))'
  r'(?![A-Za-z0-9_-])',
  caseSensitive: false,
  multiLine: true,
);

const Set<String> _trailingLinkPunctuation = {
  '.',
  ',',
  '!',
  '?',
  ';',
  ':',
  '"',
  "'",
};

const Set<String> _commonFileExtensions = {
  'jpg',
  'jpeg',
  'png',
  'gif',
  'webp',
  'bmp',
  'svg',
  'mp4',
  'm4v',
  'mov',
  'mkv',
  'avi',
  'webm',
  'mp3',
  'm4a',
  'aac',
  'wav',
  'flac',
  'ogg',
  'pdf',
  'doc',
  'docx',
  'xls',
  'xlsx',
  'ppt',
  'pptx',
  'txt',
  'csv',
  'json',
  'xml',
  'zip',
  'rar',
  '7z',
  'tar',
  'gz',
  'bz2',
  'exe',
  'dmg',
  'apk',
  'ipa',
};

int _characterCount(String value, int end, String character) {
  var count = 0;

  for (var index = 0; index < end; index++) {
    if (value[index] == character) count++;
  }

  return count;
}

int _trimMessageLinkEnd(String value) {
  var end = value.length;

  while (end > 0) {
    final last = value[end - 1];

    if (_trailingLinkPunctuation.contains(last)) {
      end--;
      continue;
    }

    if (last == ')' &&
        _characterCount(value, end, ')') > _characterCount(value, end, '(')) {
      end--;
      continue;
    }

    if (last == ']' &&
        _characterCount(value, end, ']') > _characterCount(value, end, '[')) {
      end--;
      continue;
    }

    if (last == '}' &&
        _characterCount(value, end, '}') > _characterCount(value, end, '{')) {
      end--;
      continue;
    }

    break;
  }

  return end;
}

List<MessageLinkMatch> messageLinks(String text) {
  final links = <MessageLinkMatch>[];

  for (final match in _messageLinkPattern.allMatches(text)) {
    final boundary = match.group(1) ?? '';
    final candidate = match.group(2);

    if (candidate == null) continue;

    final trimmedLength = _trimMessageLinkEnd(candidate);
    if (trimmedLength <= 0) continue;

    final visibleText = candidate.substring(0, trimmedLength);
    final lowerText = visibleText.toLowerCase();
    final hasScheme =
        lowerText.startsWith('http://') || lowerText.startsWith('https://');
    final hasWww = lowerText.startsWith('www.');
    final normalized = hasScheme ? visibleText : 'https://$visibleText';
    final uri = Uri.tryParse(normalized);

    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      continue;
    }

    if (!hasScheme && !hasWww) {
      if (!uri.host.contains('.')) continue;

      final suffix = uri.host.split('.').last.toLowerCase();
      if (_commonFileExtensions.contains(suffix)) continue;
    }

    final start = match.start + boundary.length;

    links.add(
      MessageLinkMatch(
        start: start,
        end: start + visibleText.length,
        text: visibleText,
        uri: uri,
      ),
    );
  }

  return links;
}

Future<bool> _launchExternalMessageLink(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

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

class ColorEmojiText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final bool selectable;
  final int? maxLines;
  final TextOverflow overflow;
  final MessageLinkLauncher? linkLauncher;

  const ColorEmojiText(
    this.text, {
    this.style,
    this.selectable = false,
    this.maxLines,
    this.overflow = TextOverflow.clip,
    this.linkLauncher,
    super.key,
  });

  @override
  State<ColorEmojiText> createState() => _ColorEmojiTextState();
}

class _ColorEmojiTextState extends State<ColorEmojiText> {
  List<MessageLinkMatch> _links = const [];
  final List<TapGestureRecognizer> _linkRecognizers = [];

  @override
  void initState() {
    super.initState();
    _synchronizeLinks();
  }

  @override
  void didUpdateWidget(ColorEmojiText oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.text != widget.text ||
        oldWidget.linkLauncher != widget.linkLauncher) {
      _synchronizeLinks();
    }
  }

  void _synchronizeLinks() {
    _disposeLinkRecognizers();
    _links = messageLinks(widget.text);

    for (final link in _links) {
      _linkRecognizers.add(
        TapGestureRecognizer()
          ..onTap = () {
            unawaited(_openLink(link.uri));
          },
      );
    }
  }

  void _disposeLinkRecognizers() {
    for (final recognizer in _linkRecognizers) {
      recognizer.dispose();
    }

    _linkRecognizers.clear();
  }

  List<InlineSpan> _buildSpans() {
    if (_links.isEmpty) {
      return colorEmojiTextSpans(
        widget.text,
        emojiStyle: emojiGlyphStyle(),
        parentStyle: widget.style,
      );
    }

    final spans = <InlineSpan>[];
    var cursor = 0;

    void appendPlainText(String value) {
      if (value.isEmpty) return;

      spans.addAll(
        colorEmojiTextSpans(
          value,
          emojiStyle: emojiGlyphStyle(),
          parentStyle: widget.style,
        ),
      );
    }

    for (var index = 0; index < _links.length; index++) {
      final link = _links[index];

      appendPlainText(widget.text.substring(cursor, link.start));

      spans.add(
        TextSpan(
          text: link.text,
          style: const TextStyle(
            color: Colors.blue,
            decoration: TextDecoration.underline,
            decorationColor: Colors.blue,
          ),
          recognizer: _linkRecognizers[index],
          mouseCursor: SystemMouseCursors.click,
          semanticsLabel: 'Link ${link.text}',
        ),
      );

      cursor = link.end;
    }

    appendPlainText(widget.text.substring(cursor));
    return spans;
  }

  Future<void> _openLink(Uri uri) async {
    final launcher = widget.linkLauncher ?? _launchExternalMessageLink;
    var opened = false;

    try {
      opened = await launcher(uri);
    } catch (_) {
      opened = false;
    }

    if (!opened && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('The link could not be opened.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final span = TextSpan(style: widget.style, children: _buildSpans());

    if (widget.selectable) {
      return SelectableText.rich(span, maxLines: widget.maxLines);
    }

    return Text.rich(
      span,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
    );
  }

  @override
  void dispose() {
    _disposeLinkRecognizers();
    super.dispose();
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
