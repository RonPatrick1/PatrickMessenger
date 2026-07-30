import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

class PictureSaveResult {
  final String message;

  const PictureSaveResult(this.message);
}

class PictureSaveService {
  static const _channel = MethodChannel(
    'com.patricklamphier.patrickMessenger/media_save',
  );

  static Future<PictureSaveResult?> save({
    required Uint8List bytes,
    required String name,
    required String mimeType,
  }) async {
    final safeName = _safeName(name, mimeType);
    if (_desktop) {
      final destination = await getSaveLocation(suggestedName: safeName);
      if (destination == null) return null;
      await File(destination.path).writeAsBytes(bytes, flush: true);
      return PictureSaveResult('Saved to ${destination.path}');
    }

    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      await _channel.invokeMethod<void>('saveImage', {
        'bytes': bytes,
        'name': safeName,
        'mimeType': mimeType,
      });
      return const PictureSaveResult('Saved to Photos');
    }
    throw UnsupportedError('Saving pictures is not supported here.');
  }

  static bool get _desktop =>
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows;

  static String _safeName(String original, String mimeType) {
    var name = path
        .basename(original)
        .replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_')
        .trim();
    if (name.isEmpty) name = 'Patrick Messenger picture';
    if (path.extension(name).isEmpty) {
      name += switch (mimeType.toLowerCase()) {
        'image/png' => '.png',
        'image/gif' => '.gif',
        'image/webp' => '.webp',
        _ => '.jpg',
      };
    }
    return name;
  }
}
