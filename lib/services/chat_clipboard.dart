import 'dart:async';
import 'dart:typed_data';

import 'package:super_clipboard/super_clipboard.dart';

class ClipboardImage {
  final Uint8List bytes;
  final String filename;
  final String mimeType;

  const ClipboardImage({
    required this.bytes,
    required this.filename,
    required this.mimeType,
  });
}

class ChatClipboardContents {
  final ClipboardImage? image;
  final String? text;

  const ChatClipboardContents({this.image, this.text});
}

class ChatClipboard {
  static const maximumImageBytes = 25 * 1024 * 1024;

  static const _imageFormats = [
    (format: Formats.png, extension: 'png', mimeType: 'image/png'),
    (format: Formats.jpeg, extension: 'jpg', mimeType: 'image/jpeg'),
    (format: Formats.gif, extension: 'gif', mimeType: 'image/gif'),
    (format: Formats.webp, extension: 'webp', mimeType: 'image/webp'),
  ];

  Future<ChatClipboardContents> read() async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) {
      throw UnsupportedError(
        'Image clipboard access is unavailable on this device.',
      );
    }

    final reader = await clipboard.read();
    for (final candidate in _imageFormats) {
      if (!reader.canProvide(candidate.format)) continue;
      final image = await _readImage(
        reader,
        format: candidate.format,
        extension: candidate.extension,
        mimeType: candidate.mimeType,
      );
      if (image != null) return ChatClipboardContents(image: image);
    }

    return ChatClipboardContents(
      text: await reader.readValue(Formats.plainText),
    );
  }

  Future<ClipboardImage?> _readImage(
    ClipboardReader reader, {
    required FileFormat format,
    required String extension,
    required String mimeType,
  }) {
    final completer = Completer<ClipboardImage?>();
    final progress = reader.getFile(
      format,
      (file) async {
        try {
          final declaredSize = file.fileSize;
          if (declaredSize != null && declaredSize > maximumImageBytes) {
            throw const FormatException(
              'The clipboard picture is larger than 25 MB.',
            );
          }
          final bytes = await file.readAll();
          if (bytes.length > maximumImageBytes) {
            throw const FormatException(
              'The clipboard picture is larger than 25 MB.',
            );
          }
          if (!completer.isCompleted) {
            completer.complete(
              ClipboardImage(
                bytes: bytes,
                filename: file.fileName ?? 'pasted-picture.$extension',
                mimeType: mimeType,
              ),
            );
          }
        } catch (error, stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        }
      },
      onError: (error) {
        if (!completer.isCompleted) completer.completeError(error);
      },
    );
    if (progress == null && !completer.isCompleted) {
      completer.complete(null);
    }
    return completer.future;
  }
}
