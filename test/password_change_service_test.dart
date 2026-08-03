import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:patrick_messenger/account/password_change_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('password change validation', () {
    test('requires the current password', () {
      expect(
        validatePasswordChange(
          currentPassword: '',
          newPassword: 'new password',
          confirmation: 'new password',
        ),
        'Enter your current password.',
      );
    });

    test('requires a new password of at least eight characters', () {
      expect(
        validatePasswordChange(
          currentPassword: 'temporary',
          newPassword: 'short',
          confirmation: 'short',
        ),
        'Use at least 8 characters.',
      );
    });

    test('requires matching, different passwords', () {
      expect(
        validatePasswordChange(
          currentPassword: 'temporary',
          newPassword: 'new password',
          confirmation: 'different password',
        ),
        'The new passwords do not match.',
      );
      expect(
        validatePasswordChange(
          currentPassword: 'same password',
          newPassword: 'same password',
          confirmation: 'same password',
        ),
        'Choose a password different from your current password.',
      );
    });

    test('accepts a valid replacement', () {
      expect(
        validatePasswordChange(
          currentPassword: 'temporary',
          newPassword: 'private replacement',
          confirmation: 'private replacement',
        ),
        isNull,
      );
    });
  });

  test(
    'sends password authentication without logging out other devices',
    () async {
      sqfliteFfiInit();
      final database = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
      );
      final matrixDatabase = await MatrixSdkDatabase.init(
        'password_change_test',
        database: database,
        sqfliteFactory: databaseFactoryFfi,
      );
      final client = Client(
        'password change test',
        database: matrixDatabase,
        httpClient: FakeMatrixApi(),
      );
      addTearDown(() => client.dispose(closeDatabase: true));

      await client.checkHomeserver(
        Uri.parse('https://fakeserver.notexisting'),
        checkWellKnown: false,
      );
      await client.login(
        LoginType.mLoginPassword,
        identifier: AuthenticationUserIdentifier(user: 'test'),
        password: 'temporary',
      );
      await client.abortSync();
      FakeMatrixApi.calledEndpoints.clear();

      await changeOwnPassword(
        client: client,
        currentPassword: 'temporary',
        newPassword: 'private replacement',
      );

      final requests =
          FakeMatrixApi.calledEndpoints['/client/v3/account/password'];
      expect(requests, hasLength(1));
      final body =
          jsonDecode(requests!.single as String) as Map<String, Object?>;
      expect(body['new_password'], 'private replacement');
      expect(body['logout_devices'], isFalse);
      expect(body['auth'], {
        'type': AuthenticationTypes.password,
        'password': 'temporary',
        'identifier': {
          'type': 'm.id.user',
          'user': '@test:fakeServer.notExisting',
        },
      });
    },
  );

  test('turns Matrix authentication errors into useful messages', () {
    expect(
      passwordChangeErrorMessage(
        MatrixException.fromJson({
          'errcode': 'M_FORBIDDEN',
          'error': 'Invalid password',
        }),
      ),
      'The current password is incorrect.',
    );
    expect(
      passwordChangeErrorMessage(
        MatrixException.fromJson({
          'errcode': 'M_WEAK_PASSWORD',
          'error': 'Password is too weak',
        }),
      ),
      'The homeserver rejected that password as too weak.',
    );
  });
}
