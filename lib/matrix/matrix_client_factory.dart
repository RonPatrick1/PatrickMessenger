import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as flutter_vodozemac;
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'linux_sqlite_loader.dart';

Future<void> _initializeVodozemac() => flutter_vodozemac.init();

class MatrixClientFactory {
  static const _databaseName = 'patrick_messenger';

  static Future<Client> create() async {
    await _initializeVodozemac();

    final supportDirectory = await getApplicationSupportDirectory();
    final mediaDirectory = Directory(
      path.join(supportDirectory.path, 'encrypted_media_cache'),
    );
    await mediaDirectory.create(recursive: true);

    final databasePath = path.join(
      supportDirectory.path,
      'patrick_messenger.sqlite',
    );
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
    await client.init();
    return client;
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
