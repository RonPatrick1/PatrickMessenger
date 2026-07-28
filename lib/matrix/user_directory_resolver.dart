import 'package:matrix/matrix.dart';

import '../config/app_config.dart';

class UserDirectoryResolutionException implements Exception {
  final String message;

  const UserDirectoryResolutionException(this.message);

  @override
  String toString() => message;
}

class UserDirectoryResolver {
  final Client client;
  final AppConfig config;

  const UserDirectoryResolver({required this.client, required this.config});

  Future<Profile> resolve(String input) async {
    final query = input.trim();
    if (query.isEmpty) {
      throw const UserDirectoryResolutionException('Enter a name or username.');
    }

    if (query.startsWith('@')) {
      if (!query.isValidMatrixIdStrict()) {
        throw const UserDirectoryResolutionException(
          'That account ID is not valid.',
        );
      }
      if (query.domain?.toLowerCase() != config.serverName.toLowerCase()) {
        throw UserDirectoryResolutionException(
          'Only people on ${config.serverName} can be messaged.',
        );
      }
    } else if (query.contains(':')) {
      throw const UserDirectoryResolutionException(
        'Enter a display name, username, or complete account ID.',
      );
    }

    final SearchUserDirectoryResponse response;
    try {
      response = await client.searchUserDirectory(query, limit: 50);
    } catch (_) {
      throw const UserDirectoryResolutionException(
        'Accounts could not be looked up. Check your connection and try again.',
      );
    }

    final profile = selectExactMatch(
      query: query,
      serverName: config.serverName,
      profiles: response.results,
    );
    if (profile == null) {
      throw UserDirectoryResolutionException(
        'No account exactly matches "$query". Try the person\'s username.',
      );
    }
    if (profile.userId == client.userID) {
      throw const UserDirectoryResolutionException('Choose another account.');
    }
    return profile;
  }
}

Profile? selectExactMatch({
  required String query,
  required String serverName,
  required Iterable<Profile> profiles,
}) {
  final normalizedQuery = _normalize(query);
  final candidates = profiles
      .where(
        (profile) =>
            profile.userId.isValidMatrixIdStrict() &&
            profile.userId.domain?.toLowerCase() == serverName.toLowerCase(),
      )
      .toList();

  if (query.startsWith('@')) {
    return _onlyMatch(
      candidates.where(
        (profile) => profile.userId.toLowerCase() == query.toLowerCase(),
      ),
      query,
    );
  }

  final localpartMatches = candidates.where(
    (profile) => profile.userId.localpart?.toLowerCase() == query.toLowerCase(),
  );
  final localpartMatch = _onlyMatch(localpartMatches, query);
  if (localpartMatch != null) return localpartMatch;

  final displayNameMatches = candidates.where(
    (profile) => _normalize(profile.displayName ?? '') == normalizedQuery,
  );
  final displayNameMatch = _onlyMatch(displayNameMatches, query);
  if (displayNameMatch != null) return displayNameMatch;

  final readableUsernameMatches = candidates.where((profile) {
    final localpart = profile.userId.localpart ?? '';
    return _normalize(localpart.replaceAll(RegExp(r'[_\-.]+'), ' ')) ==
        normalizedQuery;
  });
  return _onlyMatch(readableUsernameMatches, query);
}

Profile? _onlyMatch(Iterable<Profile> matches, String query) {
  final unique = <String, Profile>{
    for (final match in matches) match.userId.toLowerCase(): match,
  }.values.toList();
  if (unique.length > 1) {
    throw UserDirectoryResolutionException(
      'More than one account matches "$query". Enter the username instead.',
    );
  }
  return unique.firstOrNull;
}

String _normalize(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
