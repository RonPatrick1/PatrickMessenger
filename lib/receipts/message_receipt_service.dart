import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import '../archive/archive_contract.dart';
import 'read_receipt_preferences.dart';

enum MessageReceiptState { sending, sent, delivered, read }

class MessageReceiptSummary {
  final MessageReceiptState state;
  final int completed;
  final int total;

  const MessageReceiptSummary(this.state, this.completed, this.total);
}

class MessageReceiptService extends ChangeNotifier {
  final Client client;
  final ReadReceiptPreferenceController preferences;
  final Map<String, Set<String>> _delivered = {};
  final Map<String, Set<String>> _read = {};
  final Map<String, Map<String, int>> _deliveredThrough = {};
  final Map<String, Map<String, int>> _readThrough = {};
  final Set<String> _sentDeliveryReceipts = {};
  final Set<String> _sentReadReceipts = {};
  final Map<String, Map<String, String>> _matrixReceiptEventIds = {};
  StreamSubscription<Event>? _timelineSubscription;
  StreamSubscription<SyncUpdate>? _syncSubscription;

  MessageReceiptService(this.client, this.preferences);

  Future<void> initialize() async {
    _timelineSubscription = client.onTimelineEvent.stream.listen(_handleEvent);
    _syncSubscription = client.onSync.stream.listen(
      (_) => unawaited(_refreshMatrixReadReceipts()),
    );
    var changed = false;
    for (final room in client.rooms) {
      try {
        final timeline = await room.getTimeline();
        for (final event in timeline.events.reversed) {
          _handleReceiptEvent(event);
          changed = _recordReplyReadEvidence(event) || changed;
        }
        timeline.cancelSubscriptions();
      } catch (_) {
        // A room can still be opened offline; receipts will populate from its
        // timeline as sync events arrive.
      }
    }
    changed = await _refreshMatrixReadReceipts(notify: false) || changed;
    if (changed) notifyListeners();
  }

  void _handleEvent(Event event) {
    if (event.type == receiptEventType) {
      _handleReceiptEvent(event);
      return;
    }
    if (event.type != EventTypes.Message ||
        event.redacted ||
        event.relationshipType == RelationshipTypes.edit ||
        event.senderId == client.userID ||
        !event.status.isSynced) {
      return;
    }
    if (_recordReplyReadEvidence(event)) notifyListeners();
    unawaited(_sendReceipt(event, 'delivered'));
  }

  /// A message sent by another participant proves that participant had the
  /// conversation open through at least the messages preceding their reply.
  /// This keeps read indicators useful while older Patrick Messenger clients
  /// are still in circulation and do not yet send the app's private receipt
  /// events.
  bool _recordReplyReadEvidence(Event event) {
    if (event.type != EventTypes.Message ||
        event.redacted ||
        event.relationshipType == RelationshipTypes.edit ||
        event.senderId == client.userID ||
        !event.status.isSynced) {
      return false;
    }
    return _updateThrough(
      _readThrough,
      event.room.id,
      event.senderId,
      event.originServerTs.millisecondsSinceEpoch,
    );
  }

  /// Import standard Matrix public read receipts as a fallback/interoperable
  /// source. The custom encrypted receipts remain the primary source because
  /// they can also represent delivery and are retained in room history.
  Future<bool> _refreshMatrixReadReceipts({bool notify = true}) async {
    var changed = false;
    for (final room in client.rooms) {
      final receipts = <String, LatestReceiptStateData>{
        ...room.receiptState.global.otherUsers,
        ...?room.receiptState.mainThread?.otherUsers,
      };
      for (final entry in receipts.entries) {
        if (entry.key == client.userID) continue;
        final knownIds = _matrixReceiptEventIds.putIfAbsent(room.id, () => {});
        if (knownIds[entry.key] == entry.value.eventId) continue;
        try {
          final target = await room.getEventById(entry.value.eventId);
          if (target == null) continue;
          knownIds[entry.key] = entry.value.eventId;
          changed =
              _updateThrough(
                _readThrough,
                room.id,
                entry.key,
                target.originServerTs.millisecondsSinceEpoch,
              ) ||
              changed;
        } catch (_) {
          // The receipt target may be outside this device's current history.
          // A later sync/history load can resolve it without blocking chat.
        }
      }
    }
    if (changed && notify) notifyListeners();
    return changed;
  }

  bool _updateThrough(
    Map<String, Map<String, int>> destination,
    String roomId,
    String userId,
    int timestamp,
  ) {
    final byUser = destination.putIfAbsent(roomId, () => {});
    final old = byUser[userId];
    if (old != null && old >= timestamp) return false;
    byUser[userId] = timestamp;
    return true;
  }

  void _handleReceiptEvent(Event event) {
    if (event.type != receiptEventType) return;
    final target = event.content['event_id']?.toString();
    final state = event.content['state']?.toString();
    if (target == null || target.isEmpty || event.senderId == client.userID) {
      return;
    }
    final through =
        (event.content['through_timestamp'] as num?)?.toInt() ??
        event.originServerTs.millisecondsSinceEpoch;
    if (state == 'read') {
      _read.putIfAbsent(target, () => {}).add(event.senderId);
      _delivered.putIfAbsent(target, () => {}).add(event.senderId);
      _readThrough
          .putIfAbsent(event.room.id, () => {})
          .update(
            event.senderId,
            (old) => old > through ? old : through,
            ifAbsent: () => through,
          );
    } else if (state == 'delivered') {
      _delivered.putIfAbsent(target, () => {}).add(event.senderId);
      _deliveredThrough
          .putIfAbsent(event.room.id, () => {})
          .update(
            event.senderId,
            (old) => old > through ? old : through,
            ifAbsent: () => through,
          );
    }
    notifyListeners();
  }

  Future<void> markRead(Iterable<Event> events) async {
    if (!preferences.enabled) return;
    final latest = events
        .where(
          (event) =>
              event.type == EventTypes.Message &&
              event.senderId != client.userID &&
              event.status.isSynced,
        )
        .firstOrNull;
    if (latest != null) await _sendReceipt(latest, 'read');
  }

  Future<void> _sendReceipt(Event event, String state) async {
    final sent = state == 'read' ? _sentReadReceipts : _sentDeliveryReceipts;
    final key = '${event.room.id}|${event.eventId}';
    if (!sent.add(key)) return;
    try {
      await event.room.sendEvent(
        {
          'event_id': event.eventId,
          'state': state,
          'through_timestamp': event.originServerTs.millisecondsSinceEpoch,
          'm.relates_to': controlRelation(event.eventId),
        },
        type: receiptEventType,
        displayPendingEvent: false,
      );
    } catch (_) {
      sent.remove(key);
    }
  }

  MessageReceiptSummary summary(Event event) {
    if (!event.status.isSent) {
      return const MessageReceiptSummary(MessageReceiptState.sending, 0, 0);
    }
    final recipients =
        (event.content[messageRecipientsKey] as List? ?? const [])
            .whereType<String>()
            .where((id) => id != client.userID)
            .toSet();
    if (recipients.isEmpty) {
      return const MessageReceiptSummary(MessageReceiptState.sent, 0, 0);
    }
    final timestamp = event.originServerTs.millisecondsSinceEpoch;
    final readUsers = <String>{
      ...?_read[event.eventId],
      for (final entry in (_readThrough[event.room.id] ?? const {}).entries)
        if (entry.value >= timestamp) entry.key,
    }..retainAll(recipients);
    final deliveredUsers = <String>{
      ...?_delivered[event.eventId],
      ...readUsers,
      for (final entry
          in (_deliveredThrough[event.room.id] ?? const {}).entries)
        if (entry.value >= timestamp) entry.key,
    }..retainAll(recipients);
    final read = readUsers.length;
    final delivered = deliveredUsers.length;
    if (read > 0) {
      return MessageReceiptSummary(
        MessageReceiptState.read,
        read,
        recipients.length,
      );
    }
    if (delivered > 0) {
      return MessageReceiptSummary(
        MessageReceiptState.delivered,
        delivered,
        recipients.length,
      );
    }
    return MessageReceiptSummary(
      MessageReceiptState.sent,
      0,
      recipients.length,
    );
  }

  @override
  void dispose() {
    _timelineSubscription?.cancel();
    _syncSubscription?.cancel();
    super.dispose();
  }
}
