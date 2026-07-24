import 'package:matrix/matrix.dart';

String readableMatrixUserName(User user) {
  return readableMatrixProfileName(
    userId: user.id,
    displayName: user.displayName,
  );
}

String readableMatrixProfileName({
  required String userId,
  String? displayName,
}) {
  final localpart = userId.localpart ?? userId.replaceFirst('@', '');
  final trimmed = displayName?.trim();
  if (trimmed != null &&
      trimmed.isNotEmpty &&
      trimmed.toLowerCase() != localpart.toLowerCase()) {
    return trimmed;
  }
  return humanizeMatrixLocalpart(localpart);
}

String humanizeMatrixLocalpart(String localpart) {
  final words = localpart
      .replaceAll(RegExp(r'[_-]+'), ' ')
      .trim()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .map(
        (word) => word.length == 1
            ? word.toUpperCase()
            : '${word[0].toUpperCase()}${word.substring(1)}',
      );
  final readable = words.join(' ');
  return readable.isEmpty ? 'Unknown user' : readable;
}

String readableMatrixRoomName(Room room) {
  var name = room.getLocalizedDisplayname();
  final heroIds = <String>{...?room.summary.mHeroes, ?room.directChatMatrixID};
  for (final userId in heroIds) {
    final user = room.unsafeGetUserFromMemoryOrFallback(userId);
    final raw = user.calcDisplayname();
    final readable = readableMatrixUserName(user);
    if (raw != readable) name = name.replaceAll(raw, readable);
  }
  return name;
}
