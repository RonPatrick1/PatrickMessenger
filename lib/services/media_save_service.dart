import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class MediaSaveResult {
  final String message;

  const MediaSaveResult(this.message);
}

class MediaSaveService {
  static const _channel = MethodChannel(
    'com.patricklamphier.patrickMessenger/media_save',
  );

  static Future<MediaSaveResult?> saveImage({
    required Uint8List bytes,
    required String name,
    required String mimeType,
  }) async {
    final safeName = _safeName(name, mimeType, video: false);
    if (_desktop) {
      return _saveDesktop(bytes: bytes, safeName: safeName);
    }
    if (_mobile) {
      await _channel.invokeMethod<void>('saveImage', {
        'bytes': bytes,
        'name': safeName,
        'mimeType': mimeType,
      });
      return const MediaSaveResult('Saved to Photos');
    }
    throw UnsupportedError('Saving pictures is not supported here.');
  }

  static Future<MediaSaveResult?> saveVideo({
    required Uint8List bytes,
    required String name,
    required String mimeType,
  }) async {
    final safeName = _safeName(name, mimeType, video: true);
    if (_desktop) {
      return _saveDesktop(bytes: bytes, safeName: safeName);
    }
    if (_mobile) {
      final temporaryDirectory = await getTemporaryDirectory();
      final temporaryFile = File(
        path.join(
          temporaryDirectory.path,
          'patrick-save-${DateTime.now().microsecondsSinceEpoch}-$safeName',
        ),
      );
      try {
        await temporaryFile.writeAsBytes(bytes, flush: true);
        await _channel.invokeMethod<void>('saveVideo', {
          'path': temporaryFile.path,
          'name': safeName,
          'mimeType': mimeType,
        });
        return const MediaSaveResult('Saved to Photos');
      } finally {
        try {
          if (await temporaryFile.exists()) await temporaryFile.delete();
        } catch (_) {
          // The operating system also clears its temporary directory.
        }
      }
    }
    throw UnsupportedError('Saving videos is not supported here.');
  }

  static Future<MediaSaveResult?> _saveDesktop({
    required Uint8List bytes,
    required String safeName,
  }) async {
    final destination = await getSaveLocation(suggestedName: safeName);
    if (destination == null) return null;
    await File(destination.path).writeAsBytes(bytes, flush: true);
    return MediaSaveResult('Saved to ${destination.path}');
  }

  static bool get _desktop =>
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows;

  static bool get _mobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  static String _safeName(
    String original,
    String mimeType, {
    required bool video,
  }) {
    var name = path
        .basename(original)
        .replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_')
        .trim();
    if (name.isEmpty) {
      name = video ? 'Patrick Messenger video' : 'Patrick Messenger picture';
    }
    if (path.extension(name).isEmpty) {
      name += video
          ? switch (mimeType.toLowerCase()) {
              'video/quicktime' => '.mov',
              'video/webm' => '.webm',
              'video/x-matroska' => '.mkv',
              _ => '.mp4',
            }
          : switch (mimeType.toLowerCase()) {
              'image/png' => '.png',
              'image/gif' => '.gif',
              'image/webp' => '.webp',
              _ => '.jpg',
            };
    }
    return name;
  }
}
