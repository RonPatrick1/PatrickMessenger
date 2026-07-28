import 'package:matrix/matrix.dart';

/// Combines the SDK timeline with the live-event fallback used by an already
/// open chat. Matrix locally echoes an outgoing message before Synapse returns
/// its permanent event ID, so event IDs alone cannot identify duplicates.
List<Event> mergeMatrixTimelineEvents({
  required Iterable<Event> timelineEvents,
  required Iterable<Event> liveEvents,
}) {
  final merged = timelineEvents.toList();
  for (final liveEvent in liveEvents) {
    final existingIndex = merged.indexWhere(
      (event) => matrixEventsShareIdentity(event, liveEvent),
    );
    if (existingIndex == -1) {
      merged.add(liveEvent);
      continue;
    }
    if (liveEvent.status.index > merged[existingIndex].status.index) {
      merged[existingIndex] = liveEvent;
    }
  }
  return merged;
}

bool matrixEventsShareIdentity(Event first, Event second) {
  final firstIds = <String>{first.eventId, ?first.transactionId};
  final secondIds = <String>{second.eventId, ?second.transactionId};
  if (firstIds.intersection(secondIds).isNotEmpty) return true;

  // Some sync paths omit unsigned.transaction_id. Only use this fallback for
  // one local echo and one synced event; two genuinely synced identical
  // messages must remain two messages.
  if (first.status.isSynced == second.status.isSynced ||
      first.senderId != second.senderId ||
      first.type != second.type ||
      first.content['msgtype'] != second.content['msgtype'] ||
      first.body != second.body) {
    return false;
  }
  final timeDifference = first.originServerTs.difference(second.originServerTs);
  return timeDifference.abs() <= const Duration(seconds: 30);
}
