import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrick_messenger/config/app_config.dart';

void main() {
  group('AppConfig', () {
    test('requires HTTPS by default', () {
      final config = AppConfig(
        homeserver: Uri.parse('http://matrix.example.test'),
        serverName: 'matrix.example.test',
      );

      expect(config.validate, throwsFormatException);
    });

    test('permits explicit insecure local development', () {
      final config = AppConfig(
        homeserver: Uri.parse('http://localhost:8008'),
        serverName: 'matrix.example.test',
        allowInsecureDevelopment: true,
      );

      expect(config.validate, returnsNormally);
    });

    test('builds a local Matrix ID from a username', () {
      final config = AppConfig(
        homeserver: Uri.parse('https://matrix.example.test'),
        serverName: 'matrix.example.test',
      );

      expect(config.matrixIdFor('alice'), '@alice:matrix.example.test');
      expect(
        config.matrixIdFor('@bob:matrix.example.test'),
        '@bob:matrix.example.test',
      );
    });

    test('accepts a Liam account on the configured homeserver', () {
      final config = AppConfig(
        homeserver: Uri.parse('https://matrix.example.test'),
        serverName: 'matrix.example.test',
        liamUserId: '@liam:matrix.example.test',
      );

      expect(config.validate, returnsNormally);
    });

    test('rejects a malformed Liam account', () {
      final config = AppConfig(
        homeserver: Uri.parse('https://matrix.example.test'),
        serverName: 'matrix.example.test',
        liamUserId: 'liam',
      );

      expect(config.validate, throwsFormatException);
    });

    test('mobile builds use the public HTTPS homeserver', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final config = AppConfig.fromEnvironment();

      expect(config.homeserver, Uri.parse('https://patrick-lamphier.com'));
      expect(config.serverName, 'matrix.patrick-lamphier.com');
      expect(config.allowInsecureDevelopment, isFalse);
    });
  });
}
