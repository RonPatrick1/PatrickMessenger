import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'matrix_client_factory.dart';

/// Serializes access to a room's outbound Megolm session across the main
/// app and any background/native send path (an Android Auto car reply, or
/// on iOS the CarPlay Intents Extension process), using a real OS-level
/// file lock rather than an in-process mutex.
///
/// matrix-dart-sdk's `KeyManager` caches each room's outbound session in
/// memory and only reloads it from the database when the cache is empty or
/// invalid. Without this lock, two processes advancing the same room's
/// session — or the main app resuming with a stale in-memory copy after a
/// backgrounded car reply advanced it on disk — can reuse a Megolm message
/// index. That's a real plaintext-recovery bug for anyone in the room, not
/// just a data race, so every path that sends new content into an
/// encrypted room must go through [guarded].
class MatrixMessageSender {
  static Future<File>? _lockFileFuture;

  static Future<File> _lockFile() {
    return _lockFileFuture ??= () async {
      // On iOS the CarPlay Intents Extension is a separate process/sandbox
      // that can only see the shared App Group container (the same place
      // the database itself lives, per MatrixClientFactory) -- not this
      // app's own Application Support directory. The lock file must live
      // wherever both processes can actually see it.
      final sharedContainerPath = defaultTargetPlatform == TargetPlatform.iOS
          ? await MatrixClientFactory.iosSharedContainerPath()
          : null;
      final directoryPath =
          sharedContainerPath ?? (await getApplicationSupportDirectory()).path;
      final file = File(path.join(directoryPath, 'outbound_session.lock'));
      if (!await file.exists()) {
        await file.create(recursive: true);
      }
      return file;
    }();
  }

  static Future<T> guarded<T>(Future<T> Function() send) async {
    final raf = await (await _lockFile()).open(mode: FileMode.write);
    try {
      await raf.lock();
      return await send();
    } finally {
      await raf.unlock();
      await raf.close();
    }
  }
}
