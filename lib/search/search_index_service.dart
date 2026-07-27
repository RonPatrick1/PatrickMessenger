import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as mobile;
import 'package:sqflite_common/sqlite_api.dart';

import '../archive/archive_contract.dart';
import '../archive/archive_models.dart';
import '../archive/archive_repository.dart';
import '../matrix/display_names.dart';
import '../matrix/linux_sqlite_loader.dart';
import 'media_ocr_service.dart';
import 'shared_search_service.dart';

enum SearchSourceKind { matrix, archive }

class MessageSearchResult {
  final String roomId;
  final String sourceId;
  final SearchSourceKind sourceKind;
  final String senderName;
  final DateTime timestamp;
  final String text;
  final bool media;

  const MessageSearchResult({
    required this.roomId,
    required this.sourceId,
    required this.sourceKind,
    required this.senderName,
    required this.timestamp,
    required this.text,
    required this.media,
  });
}

class SearchIndexService extends ChangeNotifier {
  final Client client;
  final ArchiveRepository archives;
  final SharedSearchService sharedSearch;
  final String? testingKey;

  Database? _database;
  List<int>? _hmacKey;
  StreamSubscription<Event>? _timelineSubscription;
  bool _rebuilding = false;
  int _indexedDocuments = 0;
  final Map<String, String> _resolvedTextCache = {};

  SearchIndexService({
    required this.client,
    required this.archives,
    required this.sharedSearch,
    this.testingKey,
  });

  bool get rebuilding => _rebuilding;
  int get indexedDocuments => _indexedDocuments;

  Future<void> initialize() async {
    final support = await getApplicationSupportDirectory();
    final databasePath = path.join(support.path, 'patrick_search.sqlite');
    if (Platform.isLinux) {
      _database = await createLinuxDatabaseFactory().openDatabase(
        databasePath,
        options: OpenDatabaseOptions(version: 1, onCreate: _createSchema),
      );
    } else {
      _database = await mobile.openDatabase(
        databasePath,
        version: 1,
        onCreate: _createSchema,
      );
    }
    _hmacKey = await _loadKey(support);
    final count = _firstIntValue(
      await _database!.rawQuery('SELECT COUNT(*) FROM search_documents'),
    );
    _indexedDocuments = count ?? 0;
    _timelineSubscription = client.onTimelineEvent.stream.listen((event) {
      unawaited(indexEvent(event));
    });
  }

  Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE search_documents (
        document_id TEXT PRIMARY KEY,
        room_id TEXT NOT NULL,
        source_id TEXT NOT NULL,
        source_kind TEXT NOT NULL,
        sender_id TEXT NOT NULL,
        sender_name TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        is_media INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE search_tokens (
        document_id TEXT NOT NULL,
        token TEXT NOT NULL,
        PRIMARY KEY (document_id, token)
      ) WITHOUT ROWID
    ''');
    await db.execute(
      'CREATE INDEX search_tokens_by_token ON search_tokens(token)',
    );
    await db.execute(
      'CREATE INDEX search_documents_by_room_time '
      'ON search_documents(room_id, timestamp DESC)',
    );
  }

  Future<List<int>> _loadKey(Directory supportDirectory) async {
    if (testingKey != null) return utf8.encode(testingKey!);
    final token = client.accessToken;
    if (token != null && token.isNotEmpty) {
      return sha256.convert(utf8.encode('patrick-search:$token')).bytes;
    }
    final keyFile = File(path.join(supportDirectory.path, '.search-index-key'));
    if (await keyFile.exists()) {
      return base64Url.decode(await keyFile.readAsString());
    }
    final random = Random.secure();
    final key = List<int>.generate(32, (_) => random.nextInt(256));
    await keyFile.writeAsString(base64UrlEncode(key), flush: true);
    if (!Platform.isWindows) await Process.run('chmod', ['600', keyFile.path]);
    return key;
  }

  Future<void> indexEvent(Event event) async {
    if (_database == null || event.roomId == null) return;
    if (sharedSearchControlEventTypes.contains(event.type) ||
        sharedSearch.isJoined(event.room)) {
      return;
    }
    if (event.type == EventTypes.Redaction) {
      final redacts = event.redacts;
      if (redacts != null) await removeDocument(_matrixDocumentId(redacts));
      return;
    }
    if (event.type != EventTypes.Message) return;
    if (event.redacted) {
      await removeDocument(_matrixDocumentId(event.eventId));
      return;
    }
    if (event.relationshipType == RelationshipTypes.edit) {
      final target = event.relationshipEventId;
      final replacement = event.content['m.new_content'];
      if (target != null && replacement is Map) {
        await _putDocument(
          documentId: _matrixDocumentId(target),
          roomId: event.roomId!,
          sourceId: target,
          sourceKind: SearchSourceKind.matrix,
          senderId: event.senderId,
          senderName: readableMatrixUserName(event.senderFromMemoryOrFallback),
          timestamp: event.originServerTs,
          isMedia: false,
          text: replacement['body']?.toString() ?? '',
        );
      }
      return;
    }
    var ocrText = event.content[mediaOcrKey]?.toString() ?? '';
    if (ocrText.isEmpty &&
        (event.messageType == MessageTypes.Image ||
            event.messageType == MessageTypes.Sticker)) {
      try {
        final image = await event.downloadAndDecryptAttachment();
        ocrText =
            await MediaOcrService().recognizeImage(image.bytes, image.name) ??
            '';
      } catch (_) {
        // Search still indexes the caption and filename when media or OCR is
        // unavailable on this device.
      }
    }
    final text = [
      event.body,
      event.content['filename']?.toString() ?? '',
      ocrText,
    ].where((part) => part.trim().isNotEmpty).join('\n');
    _resolvedTextCache[_matrixDocumentId(event.eventId)] = text;
    await _putDocument(
      documentId: _matrixDocumentId(event.eventId),
      roomId: event.roomId!,
      sourceId: event.eventId,
      sourceKind: SearchSourceKind.matrix,
      senderId: event.senderId,
      senderName: readableMatrixUserName(event.senderFromMemoryOrFallback),
      timestamp: event.originServerTs,
      isMedia: event.messageType != MessageTypes.Text,
      text: text,
    );
  }

  Future<void> indexArchiveRoom(ArchiveRoomData archive) async {
    if (sharedSearch.isJoined(archive.room)) return;
    await archive.load();
    for (final message in archive.messages) {
      if (message.deleted) {
        await removeDocument(_archiveDocumentId(message.id));
        continue;
      }
      final text = await _archiveSearchableText(archive, message);
      _resolvedTextCache[_archiveDocumentId(message.id)] = text;
      await _putDocument(
        documentId: _archiveDocumentId(message.id),
        roomId: archive.room.id,
        sourceId: message.id,
        sourceKind: SearchSourceKind.archive,
        senderId: message.authorMatrixId,
        senderName: message.authorName,
        timestamp: message.timestamp,
        isMedia: message.attachments.isNotEmpty,
        text: text,
      );
    }
  }

  Future<void> indexTimeline(Timeline timeline) async {
    for (final event in timeline.events) {
      await indexEvent(event);
    }
  }

  Future<void> rebuild() async {
    if (_rebuilding || _database == null) return;
    _rebuilding = true;
    notifyListeners();
    try {
      _resolvedTextCache.clear();
      await _database!.transaction((txn) async {
        await txn.delete('search_tokens');
        await txn.delete('search_documents');
      });
      await archives.loadAllRooms();
      for (final archive in archives.loadedRooms) {
        if (sharedSearch.isJoined(archive.room)) continue;
        await indexArchiveRoom(archive);
      }
      for (final room in client.rooms.where(
        (room) =>
            room.membership == Membership.join &&
            room.encrypted &&
            !sharedSearch.isJoined(room),
      )) {
        final timeline = await room.getTimeline();
        try {
          while (timeline.canRequestHistory) {
            await indexTimeline(timeline);
            await timeline.requestHistory(historyCount: 250);
          }
          await indexTimeline(timeline);
        } finally {
          timeline.cancelSubscriptions();
        }
      }
    } finally {
      _indexedDocuments =
          _firstIntValue(
            await _database!.rawQuery('SELECT COUNT(*) FROM search_documents'),
          ) ??
          0;
      _rebuilding = false;
      notifyListeners();
    }
  }

  int? _firstIntValue(List<Map<String, Object?>> rows) {
    if (rows.isEmpty || rows.first.isEmpty) return null;
    return rows.first.values.first as int?;
  }

  Future<void> _putDocument({
    required String documentId,
    required String roomId,
    required String sourceId,
    required SearchSourceKind sourceKind,
    required String senderId,
    required String senderName,
    required DateTime timestamp,
    required bool isMedia,
    required String text,
  }) async {
    if (_database == null || text.trim().isEmpty) return;
    final tokens = _indexTokens(text).map(_hashToken).toSet();
    await _database!.transaction((txn) async {
      await txn.insert('search_documents', {
        'document_id': documentId,
        'room_id': roomId,
        'source_id': sourceId,
        'source_kind': sourceKind.name,
        'sender_id': senderId,
        'sender_name': senderName,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'is_media': isMedia ? 1 : 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.delete(
        'search_tokens',
        where: 'document_id = ?',
        whereArgs: [documentId],
      );
      final batch = txn.batch();
      for (final token in tokens) {
        batch.insert('search_tokens', {
          'document_id': documentId,
          'token': token,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> removeDocument(String documentId) async {
    final database = _database;
    if (database == null) return;
    _resolvedTextCache.remove(documentId);
    await database.transaction((txn) async {
      await txn.delete(
        'search_tokens',
        where: 'document_id = ?',
        whereArgs: [documentId],
      );
      await txn.delete(
        'search_documents',
        where: 'document_id = ?',
        whereArgs: [documentId],
      );
    });
  }

  Future<void> removeLocalRoom(String roomId) async {
    final database = _database;
    if (database == null) return;
    _resolvedTextCache.clear();
    await database.transaction((txn) async {
      await txn.rawDelete(
        'DELETE FROM search_tokens WHERE document_id IN '
        '(SELECT document_id FROM search_documents WHERE room_id = ?)',
        [roomId],
      );
      await txn.delete(
        'search_documents',
        where: 'room_id = ?',
        whereArgs: [roomId],
      );
    });
    await database.execute('VACUUM');
    _indexedDocuments =
        _firstIntValue(
          await database.rawQuery('SELECT COUNT(*) FROM search_documents'),
        ) ??
        0;
    notifyListeners();
  }

  Future<List<MessageSearchResult>> search(
    String query, {
    String? roomId,
    bool mediaOnly = false,
    int limit = 100,
  }) async {
    final sharedResults = await _searchShared(
      query,
      roomId: roomId,
      mediaOnly: mediaOnly,
      limit: limit,
    );
    if (roomId != null) {
      final room = client.getRoomById(roomId);
      if (room != null && sharedSearch.isJoined(room)) return sharedResults;
    }
    final database = _database;
    if (database == null) return sharedResults;
    final words = _queryWords(query);
    if (words.isEmpty) return const [];
    final hashes = words
        .map(
          (word) => _hashToken('p:${word.substring(0, min(word.length, 24))}'),
        )
        .toList();
    final placeholders = List.filled(hashes.length, '?').join(',');
    final where = <String>[
      't.token IN ($placeholders)',
      if (roomId != null) 'd.room_id = ?',
      if (mediaOnly) 'd.is_media = 1',
    ];
    final rows = await database.rawQuery(
      '''
      SELECT d.*
      FROM search_documents d
      JOIN search_tokens t ON t.document_id = d.document_id
      WHERE ${where.join(' AND ')}
      GROUP BY d.document_id
      HAVING COUNT(DISTINCT t.token) = ?
      ORDER BY d.timestamp DESC
      LIMIT ?
    ''',
      [...hashes, ?roomId, hashes.length, limit * 3],
    );
    final normalizedQuery = _normalize(query);
    final results = <MessageSearchResult>[];
    for (final row in rows) {
      final sourceKind = SearchSourceKind.values.byName(
        row['source_kind'] as String,
      );
      final sourceId = row['source_id'] as String;
      final resultRoomId = row['room_id'] as String;
      final text = await _resolveText(sourceKind, resultRoomId, sourceId);
      if (text == null || !_matches(text, normalizedQuery, words)) continue;
      results.add(
        MessageSearchResult(
          roomId: resultRoomId,
          sourceId: sourceId,
          sourceKind: sourceKind,
          senderName: row['sender_name'] as String,
          timestamp: DateTime.fromMillisecondsSinceEpoch(
            row['timestamp'] as int,
          ),
          text: _snippet(text, words),
          media: (row['is_media'] as int) == 1,
        ),
      );
      if (results.length == limit) break;
    }
    if (sharedResults.isEmpty) return results;
    final combined = <String, MessageSearchResult>{};
    for (final result in [...sharedResults, ...results]) {
      combined['${result.roomId}:${result.sourceKind.name}:${result.sourceId}'] =
          result;
    }
    final merged = combined.values.toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return merged.take(limit).toList(growable: false);
  }

  Future<List<MessageSearchResult>> _searchShared(
    String query, {
    required String? roomId,
    required bool mediaOnly,
    required int limit,
  }) async {
    final rooms = <Room>[];
    if (roomId == null) {
      rooms.addAll(
        client.rooms.where(
          (room) =>
              room.membership == Membership.join && sharedSearch.isJoined(room),
        ),
      );
    } else {
      final room = client.getRoomById(roomId);
      if (room != null && sharedSearch.isJoined(room)) rooms.add(room);
    }
    if (rooms.isEmpty) return const [];
    final hits =
        (await Future.wait(
            rooms.map(
              (room) => sharedSearch.searchRoom(
                room,
                query,
                mediaOnly: mediaOnly,
                limit: limit,
              ),
            ),
          )).expand((values) => values).toList()
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    final words = _queryWords(query);
    final normalizedQuery = _normalize(query);
    final results = <MessageSearchResult>[];
    for (final hit in hits) {
      final result = await _resolveSharedHit(hit, normalizedQuery, words);
      if (result != null) results.add(result);
      if (results.length >= limit) break;
    }
    return results;
  }

  Future<MessageSearchResult?> _resolveSharedHit(
    SharedSearchHit hit,
    String normalizedQuery,
    List<String> words,
  ) async {
    final kind = hit.sourceKind == SearchSourceKind.archive.name
        ? SearchSourceKind.archive
        : SearchSourceKind.matrix;
    final text = await _resolveText(kind, hit.roomId, hit.sourceId);
    if (text == null || !_matches(text, normalizedQuery, words)) return null;
    final room = client.getRoomById(hit.roomId);
    if (room == null) return null;
    String senderName;
    if (kind == SearchSourceKind.archive) {
      final archive = archives.forRoom(room);
      await archive.load();
      final message = archive.message(hit.sourceId);
      if (message == null) return null;
      senderName = message.authorName;
    } else {
      final event = await room.getEventById(hit.sourceId);
      if (event == null || event.redacted) return null;
      senderName = readableMatrixUserName(event.senderFromMemoryOrFallback);
    }
    return MessageSearchResult(
      roomId: hit.roomId,
      sourceId: hit.sourceId,
      sourceKind: kind,
      senderName: senderName,
      timestamp: hit.timestamp,
      text: _snippet(text, words),
      media: hit.media,
    );
  }

  bool usesSharedSearch(String? roomId) {
    if (roomId == null) return sharedSearch.hasAnySharedRooms();
    final room = client.getRoomById(roomId);
    return room != null && sharedSearch.isJoined(room);
  }

  Future<String?> _resolveText(
    SearchSourceKind kind,
    String roomId,
    String sourceId,
  ) async {
    final documentId = kind == SearchSourceKind.archive
        ? _archiveDocumentId(sourceId)
        : _matrixDocumentId(sourceId);
    final cached = _resolvedTextCache[documentId];
    if (cached != null) return cached;
    if (kind == SearchSourceKind.archive) {
      final room = client.getRoomById(roomId);
      if (room == null) return null;
      final archive = archives.forRoom(room);
      await archive.load();
      final message = archive.message(sourceId);
      if (message == null) return null;
      final text = await _archiveSearchableText(archive, message);
      _resolvedTextCache[documentId] = text;
      return text;
    }
    final room = client.getRoomById(roomId);
    final event = await room?.getEventById(sourceId);
    if (event == null || event.redacted) return null;
    var ocrText = event.content[mediaOcrKey]?.toString() ?? '';
    if (ocrText.isEmpty &&
        (event.messageType == MessageTypes.Image ||
            event.messageType == MessageTypes.Sticker)) {
      try {
        final image = await event.downloadAndDecryptAttachment();
        ocrText =
            await MediaOcrService().recognizeImage(image.bytes, image.name) ??
            '';
      } catch (_) {}
    }
    final text = [
      event.body,
      event.content['filename']?.toString() ?? '',
      ocrText,
    ].where((part) => part.trim().isNotEmpty).join('\n');
    _resolvedTextCache[documentId] = text;
    return text;
  }

  Future<String> _archiveSearchableText(
    ArchiveRoomData archive,
    ArchiveMessage message,
  ) async {
    var text = message.searchableText;
    for (final attachment in message.attachments.where(
      (item) => item.isImage && !item.missing && (item.ocrText ?? '').isEmpty,
    )) {
      try {
        final bytes = await archive.loadAttachment(attachment);
        final recognized = await MediaOcrService().recognizeImage(
          bytes,
          attachment.name,
        );
        if (recognized != null) text = '$text\n$recognized';
      } catch (_) {
        // Captions and filenames remain searchable if media is unavailable.
      }
    }
    return text;
  }

  Iterable<String> _indexTokens(String input) sync* {
    for (final word in _queryWords(input)) {
      yield 'w:$word';
      final end = min(word.length, 24);
      for (var length = min(2, end); length <= end; length++) {
        yield 'p:${word.substring(0, length)}';
      }
    }
  }

  List<String> _queryWords(String input) => _normalize(input)
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toSet()
      .toList(growable: false);

  String _normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'''[\.,!?;:"'`()\[\]{}<>/\\|@#$%^&*+=~_-]+'''), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  String _hashToken(String token) => base64UrlEncode(
    Hmac(sha256, _hmacKey!).convert(utf8.encode(token)).bytes,
  );

  bool _matches(String text, String normalizedQuery, List<String> words) {
    final normalized = _normalize(text);
    if (normalized.contains(normalizedQuery)) return true;
    return words.every(
      (word) => normalized.split(' ').any((token) => token.startsWith(word)),
    );
  }

  String _snippet(String text, List<String> words) {
    final lower = text.toLowerCase();
    var index = -1;
    for (final word in words) {
      final candidate = lower.indexOf(word);
      if (candidate >= 0 && (index < 0 || candidate < index)) index = candidate;
    }
    if (index < 0 || text.length <= 180) return text;
    final start = max(0, index - 60);
    final end = min(text.length, start + 180);
    return '${start > 0 ? '…' : ''}${text.substring(start, end)}${end < text.length ? '…' : ''}';
  }

  String _matrixDocumentId(String eventId) => 'matrix:$eventId';
  String _archiveDocumentId(String archiveId) => 'archive:$archiveId';

  @override
  void dispose() {
    _timelineSubscription?.cancel();
    _database?.close();
    super.dispose();
  }
}
