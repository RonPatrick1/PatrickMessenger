import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as flutter_vodozemac;
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'linux_sqlite_loader.dart';

// flutter_vodozemac.init() hard-crashes if called a second time within the
// same isolate. The Matrix SDK's background crypto operations (e.g. session
// restore) can invoke the vodozemacInit callback again after the explicit
// startup call below, so this must stay idempotent per isolate.
Future<void>? _vodozemacInitialization;

Future<void> _initializeVodozemac() {
  return _vodozemacInitialization ??= flutter_vodozemac.init();
}

class MatrixClientFactory {
  static const _databaseName = 'patrick_messenger';
  static const _iosChannel = MethodChannel(
    'com.patricklamphier.patrickMessenger/apns',
  );

  static Future<Client> create({required Uri homeserver}) async {
    await _initializeVodozemac();

    final supportDirectory = await getApplicationSupportDirectory();
    final mediaDirectory = Directory(
      path.join(supportDirectory.path, 'encrypted_media_cache'),
    );
    await mediaDirectory.create(recursive: true);

    final oldDatabasePath = path.join(
      supportDirectory.path,
      'patrick_messenger.sqlite',
    );
    final sharedContainerPath = await _iosSharedContainerPath();
    final databasePath = sharedContainerPath == null
        ? oldDatabasePath
        : path.join(sharedContainerPath, 'patrick_messenger.sqlite');
    if (databasePath != oldDatabasePath) {
      await _copyExistingDatabase(oldDatabasePath, databasePath);
    }
    final (database, databaseFactory) = await _openDatabase(databasePath);
    final matrixDatabase = await MatrixSdkDatabase.init(
      _databaseName,
      database: database,
      sqfliteFactory: databaseFactory,
      maxFileSize: 10 * 1024 * 1024,
      fileStorageLocation: mediaDirectory.uri,
      deleteFilesAfterDuration: const Duration(days: 7),
    );

    final client = Client(
      'Patrick Messenger',
      database: matrixDatabase,
      nativeImplementations: NativeImplementationsIsolate(
        compute,
        vodozemacInit: _initializeVodozemac,
      ),
      receiptsPublicByDefault: false,
      requestHistoryOnLimitedTimeline: true,
    );
    // Always prefer Patrick Messenger's production endpoint over a URL stored
    // by an older client. This preserves the access token, device identity,
    // encryption account, and room keys while finishing that migration.
    await client.init(newHomeserver: homeserver);
    return client;
  }

  static Future<String?> _iosSharedContainerPath() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return null;
    try {
      return await _iosChannel.invokeMethod<String>('getSharedContainerPath');
    } on PlatformException catch (error) {
      debugPrint('Shared iOS notification storage is unavailable: $error');
      return null;
    }
  }

  static Future<void> _copyExistingDatabase(
    String oldDatabasePath,
    String sharedDatabasePath,
  ) async {
    final sharedDatabase = File(sharedDatabasePath);
    if (await sharedDatabase.exists()) return;
    final oldDatabase = File(oldDatabasePath);
    if (!await oldDatabase.exists()) return;

    await sharedDatabase.parent.create(recursive: true);
    await oldDatabase.copy(sharedDatabasePath);
    for (final suffix in const ['-wal', '-shm']) {
      final source = File('$oldDatabasePath$suffix');
      if (await source.exists()) {
        await source.copy('$sharedDatabasePath$suffix');
      }
    }
  }

  static Future<(Database, DatabaseFactory?)> _openDatabase(
    String databasePath,
  ) async {
    if (Platform.isLinux) {
      final databaseFactory = createLinuxDatabaseFactory();
      final database = await databaseFactory.openDatabase(databasePath);
      return (database, databaseFactory);
    }

    final database = await sqflite.openDatabase(databasePath);
    return (database, null);
  }
}
