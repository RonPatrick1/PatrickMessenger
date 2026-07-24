import 'dart:ffi';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart' as sqlite3_open;

/// Configures SQLite inside sqflite's Linux worker isolate.
///
/// Ubuntu's runtime package provides `libsqlite3.so.0`; the unversioned
/// `libsqlite3.so` name is only installed with the development package.
@pragma('vm:entry-point')
void initializeLinuxSqlite() {
  sqlite3_open.open.overrideFor(sqlite3_open.OperatingSystem.linux, () {
    try {
      return DynamicLibrary.open('libsqlite3.so');
    } on ArgumentError {
      return DynamicLibrary.open('libsqlite3.so.0');
    }
  });
}

DatabaseFactory createLinuxDatabaseFactory() {
  return createDatabaseFactoryFfi(ffiInit: initializeLinuxSqlite);
}
