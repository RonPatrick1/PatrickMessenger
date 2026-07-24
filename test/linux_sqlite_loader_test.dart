import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:patrick_messenger/matrix/linux_sqlite_loader.dart';

void main() {
  test('opens Ubuntu runtime SQLite from the database worker', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'patrick_messenger_sqlite_test_',
    );
    final databasePath = path.join(temporaryDirectory.path, 'test.sqlite');
    final factory = createLinuxDatabaseFactory();

    try {
      final database = await factory.openDatabase(databasePath);
      await database.execute(
        'CREATE TABLE startup_check (id INTEGER PRIMARY KEY)',
      );
      final result = await database.rawQuery(
        "SELECT name FROM sqlite_master WHERE name = 'startup_check'",
      );
      expect(result, hasLength(1));
      await database.close();
    } finally {
      await temporaryDirectory.delete(recursive: true);
    }
  });
}
