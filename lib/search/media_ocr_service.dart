import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class MediaOcrService {
  static const _channel = MethodChannel(
    'com.patricklamphier.patrickMessenger/ocr',
  );

  Future<String?> recognizeImage(Uint8List bytes, String fileName) async {
    try {
      if (defaultTargetPlatform == TargetPlatform.linux) {
        return _recognizeLinux(bytes, fileName);
      }
      if (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS) {
        final text = await _channel.invokeMethod<String>('recognize', {
          'bytes': bytes,
          'name': fileName,
        });
        final trimmed = text?.trim();
        return trimmed == null || trimmed.isEmpty ? null : trimmed;
      }
    } catch (error) {
      debugPrint('Image OCR was unavailable: $error');
    }
    return null;
  }

  Future<String?> _recognizeLinux(Uint8List bytes, String fileName) async {
    final temporary = await getTemporaryDirectory();
    final extension = path.extension(fileName).isEmpty
        ? '.png'
        : path.extension(fileName);
    final file = File(
      path.join(
        temporary.path,
        'patrick-ocr-${DateTime.now().microsecondsSinceEpoch}$extension',
      ),
    );
    try {
      await file.writeAsBytes(bytes, flush: true);
      final result = await Process.run('tesseract', [
        file.path,
        'stdout',
        '--psm',
        '6',
        '-l',
        'eng',
      ]);
      if (result.exitCode != 0) return null;
      final text = result.stdout.toString().trim();
      return text.isEmpty ? null : text;
    } on ProcessException {
      return null;
    } finally {
      if (await file.exists()) await file.delete();
    }
  }
}
