import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import '../archive/archive_contract.dart';
import '../archive/archive_models.dart';
import '../archive/archive_repository.dart';
import '../history/timeline_key_recovery.dart';

const sharedSearchResetEventType =
    'com.patricklamphier.patrick_messenger.search.reset';
const sharedSearchBatchEventType =
    'com.patricklamphier.patrick_messenger.search.batch';
const sharedSearchCommitEventType =
    'com.patricklamphier.patrick_messenger.search.commit';
const sharedSearchReadyEventType =
    'com.patricklamphier.patrick_messenger.search.ready';
const sharedSearchQueryEventType =
    'com.patricklamphier.patrick_messenger.search.query';
const sharedSearchResultsEventType =
    'com.patricklamphier.patrick_messenger.search.results';
const sharedSearchLeaveEventType =
    'com.patricklamphier.patrick_messenger.search.leave';

const sharedSearchControlEventTypes = {
  sharedSearchResetEventType,
  sharedSearchBatchEventType,
  sharedSearchCommitEventType,
  sharedSearchReadyEventType,
  sharedSearchQueryEventType,
  sharedSearchResultsEventType,
  sharedSearchLeaveEventType,
};

enum SharedSearchPhase { inviting, loadingHistory, uploading, finishing }

class SharedSearchProgress {
  final SharedSearchPhase phase;
  final int completed;
  final int total;
  final String message;

  const SharedSearchProgress({
    required this.phase,
    required this.completed,
    required this.total,
    required this.message,
  });

  double? get fraction => total <= 0 ? null : completed / total;
}

class SharedSearchHit {
  final String roomId;
  final String sourceId;
  final String sourceKind;
  final DateTime timestamp;
  final bool media;

  const SharedSearchHit({
    required this.roomId,
    required this.sourceId,
    required this.sourceKind,
    required this.timestamp,
    required this.media,
  });
}

class SharedSearchService extends ChangeNotifier {
  static const _maxBatchBytes = 42 * 1024;
  static const _maxDocumentCharacters = 24000;

  final Client client;
  final String searchUserId;
  final Map<String, Completer<List<SharedSearchHit>>> _queryCompleters = {};
  final Map<String, Completer<int>> _backfillCompleters = {};
  StreamSubscription<Event>? _timelineSubscription;

  SharedSearchService({required this.client, required this.searchUserId});

  Future<void> initialize() async {
    _timelineSubscription ??= client.onTimelineEvent.stream.listen(
      _handleTimelineEvent,
    );
  }

  bool isJoined(Room room) => room
      .getParticipants(const [Membership.join])
      .any((user) => user.id == searchUserId);

  bool hasAnySharedRooms() => client.rooms.any(
    (room) => room.membership == Membership.join && isJoined(room),
  );

  Future<int> addAndBackfill({
    required Room room,
    required ArchiveRoomData archive,
    void Function(SharedSearchProgress progress)? onProgress,
  }) async {
    onProgress?.call(
      const SharedSearchProgress(
        phase: SharedSearchPhase.inviting,
        completed: 0,
        total: 0,
        message: 'Adding Search to this encrypted conversation…',
      ),
    );
    await _ensureJoined(room);

    final sessionId = client.generateUniqueTransactionId();
    final ready = Completer<int>();
    _backfillCompleters[sessionId] = ready;
    try {
      await _sendControl(room, sharedSearchResetEventType, {
        'session_id': sessionId,
      });
      onProgress?.call(
        const SharedSearchProgress(
          phase: SharedSearchPhase.loadingHistory,
          completed: 0,
          total: 0,
          message: 'Loading the complete encrypted conversation…',
        ),
      );

      await archive.load();
      final timeline = await room.getTimeline();
      try {
        var pages = 0;
        while (timeline.canRequestHistory) {
          await timeline.requestHistory(historyCount: 250);
          pages++;
          onProgress?.call(
            SharedSearchProgress(
              phase: SharedSearchPhase.loadingHistory,
              completed: pages,
              total: 0,
              message: 'Loading older encrypted messages…',
            ),
          );
        }
        await recoverTimelineKeys(timeline);

        final documents = <Map<String, Object?>>[
          ...timeline.events
              .map((event) => _matrixDocument(event, timeline))
              .whereType<Map<String, Object?>>(),
          ...archive.messages
              .map(_archiveDocument)
              .whereType<Map<String, Object?>>(),
        ];
        final total = documents.length;
        var completed = 0;
        var batch = <Map<String, Object?>>[];
        var batchBytes = 0;

        Future<void> flush() async {
          if (batch.isEmpty) return;
          await _sendControl(room, sharedSearchBatchEventType, {
            'session_id': sessionId,
            'documents': batch,
          });
          completed += batch.length;
          onProgress?.call(
            SharedSearchProgress(
              phase: SharedSearchPhase.uploading,
              completed: completed,
              total: total,
              message: 'Securely indexing $completed of $total messages…',
            ),
          );
          batch = <Map<String, Object?>>[];
          batchBytes = 0;
        }

        for (final document in documents) {
          final documentBytes = utf8.encode(jsonEncode(document)).length;
          if (batch.isNotEmpty &&
              (batch.length >= 100 ||
                  batchBytes + documentBytes > _maxBatchBytes)) {
            await flush();
          }
          batch.add(document);
          batchBytes += documentBytes;
        }
        await flush();
        onProgress?.call(
          SharedSearchProgress(
            phase: SharedSearchPhase.finishing,
            completed: total,
            total: total,
            message: 'Finishing the shared encrypted index…',
          ),
        );
        await _sendControl(room, sharedSearchCommitEventType, {
          'session_id': sessionId,
        });
      } finally {
        timeline.cancelSubscriptions();
      }

      final count = await ready.future.timeout(const Duration(minutes: 2));
      notifyListeners();
      return count;
    } finally {
      _backfillCompleters.remove(sessionId);
    }
  }

  Future<void> remove(Room room) async {
    if (!isJoined(room)) return;
    await _sendControl(room, sharedSearchLeaveEventType, const {});
    notifyListeners();
  }

  Future<List<SharedSearchHit>> searchRoom(
    Room room,
    String query, {
    bool mediaOnly = false,
    int limit = 100,
  }) async {
    if (!isJoined(room) || query.trim().isEmpty) return const [];
    final requestId = client.generateUniqueTransactionId();
    final completer = Completer<List<SharedSearchHit>>();
    _queryCompleters[requestId] = completer;
    try {
      await _sendControl(room, sharedSearchQueryEventType, {
        'request_id': requestId,
        'query': query,
        'media_only': mediaOnly,
        'limit': limit,
      });
      return await completer.future.timeout(const Duration(seconds: 30));
    } finally {
      _queryCompleters.remove(requestId);
    }
  }

  Future<void> _ensureJoined(Room room) async {
    var participants = await room.requestParticipants(const [
      Membership.join,
      Membership.invite,
    ], true);
    if (participants.any(
      (user) => user.id == searchUserId && user.membership == Membership.join,
    )) {
      return;
    }
    if (!participants.any(
      (user) => user.id == searchUserId && user.membership == Membership.invite,
    )) {
      await room.invite(
        searchUserId,
        reason: 'A room member enabled shared encrypted search.',
      );
    }
    for (var attempt = 0; attempt < 60; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      participants = await room.requestParticipants(const [
        Membership.join,
        Membership.invite,
      ], true);
      if (participants.any(
        (user) => user.id == searchUserId && user.membership == Membership.join,
      )) {
        notifyListeners();
        return;
      }
    }
    throw TimeoutException('Search did not join the conversation in time.');
  }

  Future<void> _sendControl(
    Room room,
    String type,
    Map<String, dynamic> content,
  ) async {
    final eventId = await room.sendEvent(
      content,
      type: type,
      displayPendingEvent: false,
    );
    if (eventId == null) {
      throw StateError('The encrypted Search event was not accepted.');
    }
  }

  Map<String, Object?>? _matrixDocument(Event event, Timeline timeline) {
    if ((event.type != EventTypes.Message &&
            event.type != EventTypes.Sticker) ||
        event.relationshipType == RelationshipTypes.edit ||
        event.redacted ||
        isUndecryptableEvent(event)) {
      return null;
    }
    final display = event.getDisplayEvent(timeline);
    if (display.redacted) return null;
    final text = _limitText(
      [
        display.calcUnlocalizedBody(
          hideReply: true,
          hideEdit: true,
          plaintextBody: true,
        ),
        display.content['filename']?.toString() ?? '',
        event.content[mediaOcrKey]?.toString() ?? '',
      ].where((part) => part.trim().isNotEmpty).join('\n'),
    );
    if (text.isEmpty) return null;
    return {
      'source_id': event.eventId,
      'source_kind': 'matrix',
      'timestamp': event.originServerTs.millisecondsSinceEpoch,
      'is_media': display.messageType != MessageTypes.Text,
      'text': text,
    };
  }

  Map<String, Object?>? _archiveDocument(ArchiveMessage message) {
    if (message.deleted) return null;
    final text = _limitText(message.searchableText);
    if (text.isEmpty) return null;
    return {
      'source_id': message.id,
      'source_kind': 'archive',
      'timestamp': message.timestamp.millisecondsSinceEpoch,
      'is_media': message.attachments.isNotEmpty,
      'text': text,
    };
  }

  String _limitText(String text) => text.length <= _maxDocumentCharacters
      ? text
      : text.substring(0, _maxDocumentCharacters);

  void _handleTimelineEvent(Event event) {
    if (event.senderId != searchUserId) return;
    if (event.type == sharedSearchResultsEventType) {
      final requestId = event.content['request_id']?.toString();
      final completer = requestId == null ? null : _queryCompleters[requestId];
      if (completer == null || completer.isCompleted) return;
      final values = event.content['results'];
      final hits = values is! List
          ? const <SharedSearchHit>[]
          : values
                .whereType<Map>()
                .map((value) {
                  final json = Map<String, dynamic>.from(value);
                  return SharedSearchHit(
                    roomId: event.room.id,
                    sourceId: json['source_id']?.toString() ?? '',
                    sourceKind: json['source_kind']?.toString() ?? 'matrix',
                    timestamp: DateTime.fromMillisecondsSinceEpoch(
                      (json['timestamp'] as num?)?.toInt() ?? 0,
                    ),
                    media: json['is_media'] == true,
                  );
                })
                .where((hit) => hit.sourceId.isNotEmpty)
                .toList(growable: false);
      completer.complete(hits);
      return;
    }
    if (event.type == sharedSearchReadyEventType) {
      final sessionId = event.content['session_id']?.toString();
      final completer = sessionId == null
          ? null
          : _backfillCompleters[sessionId];
      if (completer == null || completer.isCompleted) return;
      completer.complete(
        (event.content['document_count'] as num?)?.toInt() ?? 0,
      );
    }
  }

  @override
  void dispose() {
    _timelineSubscription?.cancel();
    for (final completer in _queryCompleters.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Shared search was stopped.'));
      }
    }
    for (final completer in _backfillCompleters.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Shared search was stopped.'));
      }
    }
    super.dispose();
  }
}
