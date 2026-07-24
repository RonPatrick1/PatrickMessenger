import 'package:matrix/matrix.dart';

class TimelineKeyRecoveryReport {
  final int restoredEventCount;
  final int missingKeyCount;
  final bool backupWasAvailable;
  final bool backupLoadFailed;

  const TimelineKeyRecoveryReport({
    required this.restoredEventCount,
    required this.missingKeyCount,
    required this.backupWasAvailable,
    required this.backupLoadFailed,
  });
}

bool isUndecryptableEvent(Event event) =>
    event.type == EventTypes.Encrypted &&
    event.messageType == MessageTypes.BadEncrypted;

/// Loads this room's backed-up encryption keys and retries every encrypted
/// event already present in [timeline]. Missing events remain in the timeline
/// so the UI can explain that a key is unavailable instead of hiding history.
Future<TimelineKeyRecoveryReport> recoverTimelineKeys(Timeline timeline) async {
  final encryption = timeline.room.client.encryption;
  if (encryption == null) {
    return TimelineKeyRecoveryReport(
      restoredEventCount: 0,
      missingKeyCount: timeline.events.where(isUndecryptableEvent).length,
      backupWasAvailable: false,
      backupLoadFailed: false,
    );
  }

  final missingBefore = timeline.events.where(isUndecryptableEvent).length;
  if (missingBefore == 0) {
    return const TimelineKeyRecoveryReport(
      restoredEventCount: 0,
      missingKeyCount: 0,
      backupWasAvailable: false,
      backupLoadFailed: false,
    );
  }

  final backupWasAvailable = await encryption.keyManager.isCached();
  var backupLoadFailed = false;
  if (backupWasAvailable) {
    try {
      await encryption.keyManager.loadAllKeysFromRoom(timeline.room.id);
    } catch (_) {
      backupLoadFailed = true;
    }
  }

  var restored = 0;
  for (var index = 0; index < timeline.events.length; index++) {
    final current = timeline.events[index];
    if (!isUndecryptableEvent(current)) continue;

    final original = current.originalSource;
    final encryptedEvent = original == null
        ? current
        : Event.fromMatrixEvent(original, timeline.room);
    final decrypted = await encryption.decryptRoomEvent(
      encryptedEvent,
      store: true,
      updateType: EventUpdateType.history,
    );
    if (!isUndecryptableEvent(decrypted)) {
      timeline.events[index] = decrypted;
      restored++;
    }
  }

  final missingAfter = timeline.events.where(isUndecryptableEvent).length;
  if (missingAfter > 0) {
    // Also ask the user's other devices. A currently online older device may
    // still have a key that was never uploaded to the recovery backup.
    timeline.requestKeys(tryOnlineBackup: true, onlineKeyBackupOnly: false);
  }

  return TimelineKeyRecoveryReport(
    restoredEventCount: restored,
    missingKeyCount: missingAfter,
    backupWasAvailable: backupWasAvailable,
    backupLoadFailed: backupLoadFailed,
  );
}
