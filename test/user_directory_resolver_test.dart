import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:patrick_messenger/matrix/user_directory_resolver.dart';

void main() {
  const serverName = 'matrix.example.test';
  final profiles = <Profile>[
    Profile(userId: '@alex_smith:$serverName', displayName: 'Alex Smith'),
    Profile(userId: '@jamie:$serverName', displayName: 'Jamie Taylor'),
  ];

  group('selectExactMatch', () {
    test('resolves a human display name', () {
      final result = selectExactMatch(
        query: 'Alex Smith',
        serverName: serverName,
        profiles: profiles,
      );

      expect(result?.userId, '@alex_smith:$serverName');
    });

    test('resolves a username and a complete account ID', () {
      expect(
        selectExactMatch(
          query: 'alex_smith',
          serverName: serverName,
          profiles: profiles,
        )?.userId,
        '@alex_smith:$serverName',
      );
      expect(
        selectExactMatch(
          query: '@alex_smith:$serverName',
          serverName: serverName,
          profiles: profiles,
        )?.userId,
        '@alex_smith:$serverName',
      );
    });

    test('does not guess from a partial name', () {
      expect(
        selectExactMatch(
          query: 'Alex',
          serverName: serverName,
          profiles: profiles,
        ),
        isNull,
      );
    });

    test('rejects ambiguous display names', () {
      expect(
        () => selectExactMatch(
          query: 'Alex Smith',
          serverName: serverName,
          profiles: [
            ...profiles,
            Profile(
              userId: '@another_alex:$serverName',
              displayName: 'Alex Smith',
            ),
          ],
        ),
        throwsA(isA<UserDirectoryResolutionException>()),
      );
    });

    test('ignores accounts on another server', () {
      expect(
        selectExactMatch(
          query: 'Alex Smith',
          serverName: serverName,
          profiles: [
            Profile(
              userId: '@alex:elsewhere.example',
              displayName: 'Alex Smith',
            ),
          ],
        ),
        isNull,
      );
    });
  });
}
