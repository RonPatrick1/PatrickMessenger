import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:patrick_messenger/matrix/user_directory_resolver.dart';

void main() {
  const serverName = 'matrix.example.test';
  final profiles = <Profile>[
    Profile(userId: '@ron_patrick:$serverName', displayName: 'Ron Patrick'),
    Profile(userId: '@elizabeth:$serverName', displayName: 'Elizabeth Patrick'),
  ];

  group('selectExactMatch', () {
    test('resolves a human display name', () {
      final result = selectExactMatch(
        query: 'Ron Patrick',
        serverName: serverName,
        profiles: profiles,
      );

      expect(result?.userId, '@ron_patrick:$serverName');
    });

    test('resolves a username and a complete account ID', () {
      expect(
        selectExactMatch(
          query: 'ron_patrick',
          serverName: serverName,
          profiles: profiles,
        )?.userId,
        '@ron_patrick:$serverName',
      );
      expect(
        selectExactMatch(
          query: '@ron_patrick:$serverName',
          serverName: serverName,
          profiles: profiles,
        )?.userId,
        '@ron_patrick:$serverName',
      );
    });

    test('does not guess from a partial name', () {
      expect(
        selectExactMatch(
          query: 'Ron',
          serverName: serverName,
          profiles: profiles,
        ),
        isNull,
      );
    });

    test('rejects ambiguous display names', () {
      expect(
        () => selectExactMatch(
          query: 'Ron Patrick',
          serverName: serverName,
          profiles: [
            ...profiles,
            Profile(
              userId: '@another_ron:$serverName',
              displayName: 'Ron Patrick',
            ),
          ],
        ),
        throwsA(isA<UserDirectoryResolutionException>()),
      );
    });

    test('ignores accounts on another server', () {
      expect(
        selectExactMatch(
          query: 'Ron Patrick',
          serverName: serverName,
          profiles: [
            Profile(
              userId: '@ron:elsewhere.example',
              displayName: 'Ron Patrick',
            ),
          ],
        ),
        isNull,
      );
    });
  });
}
