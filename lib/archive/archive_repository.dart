import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import 'archive_contract.dart';
import 'archive_models.dart';

class ArchiveRepository {
  final Client client;
  final Map<String, ArchiveRoomData> _rooms = {};

  ArchiveRepository(this.client);

  ArchiveRoomData forRoom(Room room) =>
      _rooms.putIfAbsent(room.id, () => ArchiveRoomData(room));

  Iterable<ArchiveRoomData> get loadedRooms => _rooms.values;

  void removeRoom(String roomId) {
    _rooms.remove(roomId)?.dispose();
  }

  Future<void> loadAllRooms() async {
    for (final room in client.rooms.where(
      (room) => room.membership == Membership.join && room.encrypted,
    )) {
      await forRoom(room).load();
    }
  }

  void dispose() {
    for (final room in _rooms.values) {
      room.dispose();
    }
  }
}

class ArchiveRoomData extends ChangeNotifier {
  final Room room;
  final Map<String, ArchiveMessage> _original = {};
  final Map<String, ArchiveMessage> _display = {};
  final Map<String, String> _messageManifestEvents = {};
  final Map<String, Uint8List> _mediaCache = {};
  StreamSubscription<Event>? _timelineSubscription;
  StreamSubscription<SyncUpdate>? _syncSubscription;
  final Set<String> _attemptedManifestIds = {};
  final Set<String> _knownChunkIds = {};
  final List<_PendingArchiveChunk> _pendingChunks = [];
  final List<Event> _knownOverlayEvents = [];
  Future<void>? _preparing;
  Future<void>? _loadingOlder;
  bool _knownOverlaysLoaded = false;
  bool _recentChunkLoaded = false;
  String? error;

  ArchiveRoomData(this.room) {
    _timelineSubscription = room.client.onTimelineEvent.stream
        .where((event) => event.room.id == room.id)
        .listen(_handleTimelineEvent);
    _syncSubscription = room.client.onSync.stream.listen((_) {
      final manifestIds =
          (room.states[archivePointerStateType]?.values ?? const [])
              .map((event) => event.content['manifest_event_id']?.toString())
              .whereType<String>()
              .toSet();
      if (manifestIds.difference(_attemptedManifestIds).isEmpty) return;
      unawaited(loadRecent());
    });
  }

  List<ArchiveMessage> get messages =>
      _display.values.toList(growable: false)..sort((a, b) {
        final time = b.timestamp.compareTo(a.timestamp);
        return time != 0 ? time : b.id.compareTo(a.id);
      });

  ArchiveMessage? message(String id) => _display[id];

  bool get canLoadOlder => _pendingChunks.isNotEmpty;

  /// Loads only the newest imported-history chunk so a conversation can open
  /// at its latest messages without downloading and parsing the full archive.
  Future<void> loadRecent() async {
    await _prepare();
    if (!_recentChunkLoaded && canLoadOlder) {
      await loadOlder();
      _recentChunkLoaded = true;
    }
  }

  /// Loads the next oldest imported-history chunks.
  Future<void> loadOlder({int chunkCount = 1}) async {
    await _prepare();
    final inProgress = _loadingOlder;
    if (inProgress != null) {
      await inProgress;
      return;
    }
    final future = _loadOlderChunks(chunkCount);
    _loadingOlder = future;
    try {
      await future;
    } finally {
      if (identical(_loadingOlder, future)) _loadingOlder = null;
    }
  }

  /// Loads the complete imported archive for explicit full-history work such
  /// as export and shared-search backfill.
  Future<void> load() async {
    await _prepare();
    while (canLoadOlder) {
      final inProgress = _loadingOlder;
      if (inProgress != null) {
        await inProgress;
      } else {
        await loadOlder(chunkCount: _pendingChunks.length);
      }
    }
  }

  Future<bool> loadUntilMessage(String messageId) async {
    await loadRecent();
    while (!_display.containsKey(messageId) && canLoadOlder) {
      await loadOlder();
    }
    return _display.containsKey(messageId);
  }

  Future<void> _prepare() async {
    final inProgress = _preparing;
    if (inProgress != null) return inProgress;
    final future = _prepareManifests();
    _preparing = future;
    try {
      await future;
    } finally {
      if (identical(_preparing, future)) _preparing = null;
    }
  }

  Future<void> _prepareManifests() async {
    var foundNewChunks = false;
    try {
      await room.postLoad();
      final pointers = room.states[archivePointerStateType]?.values ?? const [];
      for (final pointer in pointers) {
        final version = (pointer.content['schema_version'] as num?)?.toInt();
        if (version != archiveSchemaVersion) {
          error = 'Update Patrick Messenger to view this history.';
          continue;
        }
        final manifestEventId = pointer.content['manifest_event_id']
            ?.toString();
        if (manifestEventId == null || manifestEventId.isEmpty) continue;
        _attemptedManifestIds.add(manifestEventId);
        final manifestEvent = await room.getEventById(manifestEventId);
        if (manifestEvent == null ||
            manifestEvent.type != archiveManifestEventType) {
          continue;
        }
        final fileValue = manifestEvent.content['file'];
        if (fileValue is! Map) continue;
        final manifestBytes = await download(
          ArchiveEncryptedFileRef.fromJson(
            Map<String, dynamic>.from(fileValue),
          ),
        );
        final manifest = ArchiveManifest.fromJson(
          Map<String, dynamic>.from(
            jsonDecode(utf8.decode(manifestBytes)) as Map,
          ),
        );
        if (manifest.schemaVersion != archiveSchemaVersion ||
            manifest.roomId != room.id) {
          error = 'Update Patrick Messenger to view this history.';
          continue;
        }
        for (var index = 0; index < manifest.chunks.length; index++) {
          final chunkId = '$manifestEventId:$index';
          if (!_knownChunkIds.add(chunkId)) continue;
          foundNewChunks = true;
          _pendingChunks.add(
            _PendingArchiveChunk(
              ref: manifest.chunks[index],
              manifestEventId: manifestEventId,
              manifestLastTimestamp: manifest.lastTimestamp,
              index: index,
            ),
          );
        }
      }
      _pendingChunks.sort((a, b) {
        final byManifest = b.manifestLastTimestamp.compareTo(
          a.manifestLastTimestamp,
        );
        return byManifest != 0 ? byManifest : b.index.compareTo(a.index);
      });
      if (foundNewChunks) _recentChunkLoaded = false;
      await _loadKnownOverlays();
    } catch (loadError) {
      error = 'Signal history could not be loaded: $loadError';
    }
  }

  Future<void> _loadOlderChunks(int chunkCount) async {
    var loaded = 0;
    while (loaded < chunkCount && _pendingChunks.isNotEmpty) {
      final pending = _pendingChunks.removeAt(0);
      try {
        final compressed = await download(pending.ref);
        final decoded = GZipDecoder().decodeBytes(compressed);
        final values = jsonDecode(utf8.decode(decoded));
        if (values is! List) continue;
        for (final value in values.whereType<Map>()) {
          final message = ArchiveMessage.fromJson(
            Map<String, dynamic>.from(value),
          );
          _original.putIfAbsent(message.id, () => message);
          _display.putIfAbsent(message.id, () => message);
          _messageManifestEvents[message.id] = pending.manifestEventId;
        }
        loaded++;
      } catch (loadError) {
        error = 'Some Signal history could not be loaded: $loadError';
      }
    }
    for (final event in _knownOverlayEvents) {
      _applyOverlay(event);
    }
    notifyListeners();
  }

  Future<void> _loadKnownOverlays() async {
    if (_knownOverlaysLoaded) return;
    _knownOverlaysLoaded = true;
    final timeline = await room.getTimeline();
    try {
      for (final event in timeline.events.reversed) {
        if (event.type == archiveOverlayEventType) {
          _knownOverlayEvents.add(event);
        }
      }
    } finally {
      timeline.cancelSubscriptions();
    }
  }

  void _handleTimelineEvent(Event event) {
    if (event.type == archiveOverlayEventType) {
      _knownOverlayEvents.removeWhere(
        (known) => known.eventId == event.eventId,
      );
      _knownOverlayEvents.add(event);
    }
    if (_applyOverlay(event)) notifyListeners();
  }

  bool _applyOverlay(Event event) {
    if (event.type != archiveOverlayEventType || event.redacted) return false;
    final id = event.content['archive_id']?.toString();
    final action = event.content['action']?.toString();
    final original = id == null ? null : _original[id];
    if (original == null || action == null) return false;
    var current = _display[id] ?? original;
    switch (action) {
      case 'edit':
        if (event.senderId != original.authorMatrixId) return false;
        final body = event.content['body']?.toString();
        if (body == null || body.trim().isEmpty) return false;
        current = current.copyWith(body: body, edited: true);
      case 'delete':
        if (event.senderId != original.authorMatrixId) return false;
        current = current.copyWith(body: 'Message deleted', deleted: true);
      case 'reaction':
        final emoji = event.content['emoji']?.toString();
        if (emoji == null || emoji.isEmpty) return false;
        final remove = event.content['remove'] == true;
        final reactions = [...current.reactions]
          ..removeWhere(
            (reaction) =>
                reaction.authorMatrixId == event.senderId &&
                reaction.emoji == emoji,
          );
        if (!remove) {
          reactions.add(
            ArchiveReaction(
              authorMatrixId: event.senderId,
              authorName:
                  event.senderFromMemoryOrFallback.displayName ??
                  event.senderId,
              emoji: emoji,
              timestamp: event.originServerTs,
            ),
          );
        }
        current = current.copyWith(reactions: reactions);
      default:
        return false;
    }
    _display[id!] = current;
    return true;
  }

  Future<void> edit(String archiveId, String body) =>
      _sendOverlay(archiveId, 'edit', {'body': body});

  Future<void> delete(String archiveId) =>
      _sendOverlay(archiveId, 'delete', const {});

  Future<void> toggleReaction(String archiveId, String emoji) async {
    final message = _display[archiveId];
    if (message == null) return;
    final ownUserId = room.client.userID;
    final exists = message.reactions.any(
      (reaction) =>
          reaction.authorMatrixId == ownUserId && reaction.emoji == emoji,
    );
    await _sendOverlay(archiveId, 'reaction', {
      'emoji': emoji,
      'remove': exists,
    });
  }

  Future<void> _sendOverlay(
    String archiveId,
    String action,
    Map<String, dynamic> extra,
  ) async {
    final original = _original[archiveId];
    if (original == null) throw StateError('Archive message not found.');
    if ((action == 'edit' || action == 'delete') &&
        original.authorMatrixId != room.client.userID) {
      throw StateError('Only the original sender can change this message.');
    }
    final root = _messageManifestEvents[archiveId];
    final eventId = await room.sendEvent(
      {
        'archive_id': archiveId,
        'action': action,
        ...extra,
        if (root != null) 'm.relates_to': controlRelation(root),
      },
      type: archiveOverlayEventType,
      displayPendingEvent: false,
    );
    if (eventId == null) throw StateError('Archive action was not accepted.');
  }

  Future<Uint8List> loadAttachment(ArchiveAttachment attachment) async {
    final cached = _mediaCache[attachment.id];
    if (cached != null) return cached;
    final file = attachment.file;
    if (file == null) {
      throw StateError('Media is missing from the Signal export.');
    }
    final bytes = await download(file);
    _mediaCache[attachment.id] = bytes;
    return bytes;
  }

  Future<Uint8List> download(ArchiveEncryptedFileRef ref) async {
    final uri = Uri.parse(ref.url);
    if (uri.scheme != 'mxc' || uri.host.isEmpty || uri.pathSegments.isEmpty) {
      throw FormatException('Invalid encrypted Matrix media URL.');
    }
    final response = await room.client.getContent(
      uri.host,
      uri.pathSegments.join('/'),
    );
    final decrypted = await room.client.nativeImplementations.decryptFile(
      EncryptedFile(
        data: response.data,
        k: ref.key,
        iv: ref.iv,
        sha256: ref.sha256,
      ),
    );
    if (decrypted == null) {
      throw StateError('Encrypted archive media failed integrity checking.');
    }
    return decrypted;
  }

  @override
  void dispose() {
    _timelineSubscription?.cancel();
    _syncSubscription?.cancel();
    super.dispose();
  }
}

class _PendingArchiveChunk {
  final ArchiveEncryptedFileRef ref;
  final String manifestEventId;
  final DateTime manifestLastTimestamp;
  final int index;

  const _PendingArchiveChunk({
    required this.ref,
    required this.manifestEventId,
    required this.manifestLastTimestamp,
    required this.index,
  });
}
