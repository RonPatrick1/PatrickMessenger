import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../archive/archive_contract.dart';
import '../matrix/display_names.dart';
import '../screens/chat/message_interactions.dart';
import 'car_notification_bridge.dart';
import 'conversation_mute_controller.dart';
import 'liam_chatter_visibility.dart';
import 'notification_preferences.dart';

class MessageNotificationService {
  static const _soundChannelId = 'messages_with_sound_v1';
  static const _silentChannelId = 'messages_silent_v1';

  final Client _client;
  final NotificationPreferenceController _preferences;
  final ConversationMuteController _conversationMuteController;
  final LiamChatterVisibilityController _liamChatterVisibility;
  final String _liamUserId;
  final FlutterLocalNotificationsPlugin _plugin;
  final Queue<String> _recentEventIds = Queue<String>();
  final Set<String> _recentEventIdSet = <String>{};

  StreamSubscription<Event>? _timelineSubscription;
  // Matrix currently exposes messages decrypted after their original sync
  // only through its legacy EventUpdate stream.
  // ignore: deprecated_member_use
  StreamSubscription<EventUpdate>? _decryptedTimelineSubscription;
  StreamSubscription<Event>? _inviteSubscription;
  StreamSubscription<SyncUpdate>? _syncSubscription;
  StreamSubscription<LoginState>? _loginSubscription;
  DateTime _acceptEventsAfter = DateTime.now();
  bool _timelineReady = false;
  bool _initialized = false;

  MessageNotificationService(
    this._client,
    this._preferences,
    this._conversationMuteController,
    this._liamChatterVisibility,
    this._liamUserId, {
    FlutterLocalNotificationsPlugin? plugin,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  bool get initialized => _initialized;

  Future<void> initialize() async {
    // Events from the first sync after every process launch are catch-up data,
    // even when the restored session has a previous sync token. The SDK emits
    // its timeline events before it emits the completed SyncUpdate, so keep
    // the gate closed until that first update finishes. Otherwise reopening
    // the app can produce a notification for every message in the batch.
    _timelineReady = false;
    _acceptEventsAfter = DateTime.now().subtract(const Duration(seconds: 2));

    try {
      _initialized =
          await _plugin.initialize(
            settings: InitializationSettings(
              android: const AndroidInitializationSettings('ic_notification'),
              iOS: DarwinInitializationSettings(
                requestAlertPermission: _preferences.enabled,
                requestBadgePermission: _preferences.enabled,
                requestSoundPermission:
                    _preferences.enabled && _preferences.soundEnabled,
              ),
              macOS: DarwinInitializationSettings(
                requestAlertPermission: _preferences.enabled,
                requestBadgePermission: _preferences.enabled,
                requestSoundPermission:
                    _preferences.enabled && _preferences.soundEnabled,
              ),
              linux: LinuxInitializationSettings(
                defaultActionName: 'Open conversation',
                defaultIcon: AssetsLinuxIcon('assets/images/liam.png'),
              ),
            ),
          ) ??
          false;
      if (_initialized && defaultTargetPlatform == TargetPlatform.android) {
        await _ensureAndroidChannels();
        // Opening the app acknowledges previous message alerts. This also
        // clears notifications left by an older build.
        await _plugin.cancelAll();
      }
    } catch (error, stackTrace) {
      debugPrint('Notifications could not be initialized: $error');
      debugPrintStack(stackTrace: stackTrace);
    }

    _syncSubscription ??= _client.onSync.stream.listen((sync) {
      final shouldProcessTimeline = _timelineReady;
      _timelineReady = true;
      if (shouldProcessTimeline) {
        unawaited(_showSyncTimelineEvents(sync));
      }
    });
    _loginSubscription ??= _client.onLoginStateChanged.stream.listen((state) {
      if (state == LoginState.loggedOut) {
        _timelineReady = false;
      } else if (state == LoginState.loggedIn) {
        _timelineReady = false;
        _acceptEventsAfter = DateTime.now().subtract(
          const Duration(seconds: 2),
        );
      }
    });

    // Do not use Client.onNotification for messages here. That SDK stream
    // intentionally excludes every event whose sender is the logged-in Matrix
    // user, which also excludes a message sent from another one of the user's
    // devices. Patrick Messenger is multi-device, so the phone should notify
    // for a message sent from the same account's desktop session.
    _timelineSubscription ??= _client.onTimelineEvent.stream.listen((event) {
      if (!shouldNotifyForTimelineEvent(
        timelineReady: _timelineReady,
        eventType: event.type,
        relationshipType: event.relationshipType,
        senderId: event.senderId,
        ownUserId: _client.userID,
        transactionId: event.transactionId,
      )) {
        return;
      }
      unawaited(_showEvent(event));
    });

    // A room key can arrive in a later sync than the encrypted message. In
    // that case Matrix cannot emit a decrypted onTimelineEvent initially. It
    // retries when the key arrives and publishes a decryptedTimelineQueue
    // update instead. Listen for that recovery path so the now-readable live
    // message is not permanently skipped by notifications.
    // ignore: deprecated_member_use
    _decryptedTimelineSubscription ??= _client.onEvent.stream.listen((update) {
      if (!_timelineReady ||
          update.type != EventUpdateType.decryptedTimelineQueue) {
        return;
      }
      final room = _client.getRoomById(update.roomID);
      if (room == null) return;
      final event = Event.fromJson(update.content, room);
      if (!shouldNotifyForTimelineEvent(
        timelineReady: true,
        eventType: event.type,
        relationshipType: event.relationshipType,
        senderId: event.senderId,
        ownUserId: _client.userID,
        transactionId: event.transactionId,
      )) {
        return;
      }
      unawaited(_showEvent(event));
    });

    // Invitations are not timeline events. The SDK's notification stream is
    // still the correct decrypted source for those.
    _inviteSubscription ??= _client.onNotification.stream.listen((event) {
      if (event.type == EventTypes.RoomMember &&
          event.stateKey == _client.userID) {
        unawaited(_showEvent(event));
      }
    });
  }

  /// Matrix's higher-level notification stream intentionally filters events
  /// according to unread counts and push rules. Those filters are useful for
  /// push gateways, but they can suppress a local notification when a room is
  /// open on another device or when the same Matrix account sends from a
  /// different session. Inspecting the completed sync makes every newly
  /// received message available. The timeline listener above remains useful
  /// for the fastest path; [_remember] safely deduplicates the two sources.
  Future<void> _showSyncTimelineEvents(SyncUpdate sync) async {
    final joinedRooms = sync.rooms?.join;
    if (joinedRooms == null || joinedRooms.isEmpty) return;

    for (final roomUpdate in joinedRooms.entries) {
      final room = _client.getRoomById(roomUpdate.key);
      if (room == null) continue;

      for (final matrixEvent
          in roomUpdate.value.timeline?.events ?? const <MatrixEvent>[]) {
        // The SDK has already decrypted and stored the event before emitting
        // onSync. Prefer that stored event so edits and message previews are
        // interpreted correctly; retain the encrypted wrapper as a safe
        // fallback when keys are not available yet.
        final event =
            await room.getEventById(matrixEvent.eventId) ??
            Event.fromMatrixEvent(matrixEvent, room);
        if (!shouldNotifyForTimelineEvent(
          timelineReady: true,
          eventType: event.type,
          relationshipType: event.relationshipType,
          senderId: event.senderId,
          ownUserId: _client.userID,
          transactionId: event.transactionId,
        )) {
          continue;
        }
        await _showEvent(event);
      }
    }
  }

  Future<void> _ensureAndroidChannels() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        _soundChannelId,
        'Messages with sound',
        description: 'New encrypted messages with the default sound',
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        _silentChannelId,
        'Silent messages',
        description: 'New encrypted messages without sound',
        importance: Importance.high,
        playSound: false,
        enableVibration: true,
      ),
    );
  }

  Future<bool> requestPermission({required bool sound}) async {
    if (!_initialized) return false;
    try {
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          return await _plugin
                  .resolvePlatformSpecificImplementation<
                    AndroidFlutterLocalNotificationsPlugin
                  >()
                  ?.requestNotificationsPermission() ??
              true;
        case TargetPlatform.iOS:
          return await _plugin
                  .resolvePlatformSpecificImplementation<
                    IOSFlutterLocalNotificationsPlugin
                  >()
                  ?.requestPermissions(
                    alert: true,
                    badge: true,
                    sound: sound,
                  ) ??
              false;
        case TargetPlatform.macOS:
          return await _plugin
                  .resolvePlatformSpecificImplementation<
                    MacOSFlutterLocalNotificationsPlugin
                  >()
                  ?.requestPermissions(
                    alert: true,
                    badge: true,
                    sound: sound,
                  ) ??
              false;
        case TargetPlatform.linux:
          return true;
        case TargetPlatform.fuchsia || TargetPlatform.windows:
          return false;
      }
    } catch (error) {
      debugPrint('Notification permission request failed: $error');
      return false;
    }
  }

  Future<void> showTestNotification({required bool sound}) async {
    if (!_initialized) {
      throw StateError('Notifications are unavailable on this device.');
    }
    await _show(
      id: DateTime.now().millisecondsSinceEpoch & 0x7fffffff,
      title: 'Patrick Messenger',
      body: sound
          ? 'Notifications are on, with sound.'
          : 'Notifications are on, silently.',
      payload: 'test',
      sound: sound,
      attachmentPath: null,
    );
  }

  Future<void> _showEvent(Event event) async {
    if (!_initialized || !_preferences.enabled) return;
    if (_conversationMuteController.isMuted(event.room.id)) return;
    if (_liamChatterVisibility.isHidden(event.room.id) &&
        isLiamChatterEvent(event, liamUserId: _liamUserId)) {
      return;
    }
    if (event.originServerTs.isBefore(_acceptEventsAfter)) return;
    if (!_remember(event.eventId)) return;

    try {
      if (await _wasReadElsewhere(event)) return;
      final sender = readableMatrixUserName(event.senderFromMemoryOrFallback);
      final roomName = readableMatrixRoomName(event.room);
      final invited =
          event.type == EventTypes.RoomMember &&
          event.stateKey == _client.userID &&
          event.room.membership == Membership.invite;
      final title = !_preferences.showPreviews
          ? 'Patrick Messenger'
          : invited
          ? 'Conversation invitation'
          : event.room.isDirectChat
          ? sender
          : '$sender in $roomName';
      final body = !_preferences.showPreviews
          ? invited
                ? 'New conversation invitation'
                : 'New encrypted message'
          : invited
          ? '$sender invited you to $roomName.'
          : notificationPreview(event);
      final attachmentPath = _preferences.showPreviews
          ? await _prepareImagePreview(event)
          : null;

      final notificationId = event.eventId.hashCode & 0x7fffffff;
      await _show(
        id: notificationId,
        title: title,
        body: body,
        payload: event.room.id,
        sound: _preferences.soundEnabled,
        attachmentPath: attachmentPath,
      );

      if (!invited && _preferences.showPreviews) {
        unawaited(
          CarNotificationBridge.show(
            roomId: event.room.id,
            notificationId: notificationId,
            senderId: event.senderFromMemoryOrFallback.id,
            senderName: sender,
            conversationTitle: roomName,
            isGroupConversation: !event.room.isDirectChat,
            body: body,
          ),
        );
      }
    } catch (error, stackTrace) {
      debugPrint('Could not show message notification: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<bool> _wasReadElsewhere(Event event) async {
    if (_preferences.notifyIfReadElsewhere) return false;
    final markerId = event.room.fullyRead;
    if (markerId.isEmpty) return false;
    if (markerId == event.eventId) return true;

    try {
      final marker = await event.room.getEventById(markerId);
      return shouldSuppressNotificationForReadMarker(
        notifyIfReadElsewhere: false,
        eventId: event.eventId,
        eventTimestamp: event.originServerTs,
        fullyReadEventId: markerId,
        fullyReadTimestamp: marker?.originServerTs,
      );
    } catch (error) {
      // A stale or temporarily unavailable marker must not make a new message
      // disappear. The exact-ID case above remains safe without a lookup.
      debugPrint('Could not inspect the cross-device read marker: $error');
      return false;
    }
  }

  Future<void> _show({
    required int id,
    required String title,
    required String body,
    required String payload,
    required bool sound,
    required String? attachmentPath,
  }) {
    return _plugin.show(
      id: id,
      title: title,
      body: body,
      payload: payload,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          sound ? _soundChannelId : _silentChannelId,
          sound ? 'Messages with sound' : 'Silent messages',
          channelDescription: sound
              ? 'New encrypted messages with the default sound'
              : 'New encrypted messages without sound',
          importance: Importance.high,
          priority: Priority.high,
          playSound: sound,
          enableVibration: true,
          category: AndroidNotificationCategory.message,
          styleInformation: attachmentPath == null
              ? null
              : BigPictureStyleInformation(
                  FilePathAndroidBitmap(attachmentPath),
                  contentTitle: title,
                  summaryText: body,
                  hideExpandedLargeIcon: true,
                  showBigPictureWhenCollapsed: true,
                ),
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBanner: true,
          presentList: true,
          presentBadge: true,
          presentSound: sound,
          threadIdentifier: payload,
          attachments: attachmentPath == null
              ? null
              : <DarwinNotificationAttachment>[
                  DarwinNotificationAttachment(attachmentPath),
                ],
        ),
        macOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBanner: true,
          presentList: true,
          presentBadge: true,
          presentSound: sound,
          threadIdentifier: payload,
          attachments: attachmentPath == null
              ? null
              : <DarwinNotificationAttachment>[
                  DarwinNotificationAttachment(attachmentPath),
                ],
        ),
        linux: LinuxNotificationDetails(
          category: LinuxNotificationCategory.imReceived,
          urgency: LinuxNotificationUrgency.normal,
          suppressSound: !sound,
          defaultActionName: 'Open conversation',
        ),
      ),
    );
  }

  Future<String?> _prepareImagePreview(Event event) async {
    if ((defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS &&
            defaultTargetPlatform != TargetPlatform.macOS) ||
        event.messageType != MessageTypes.Image) {
      return null;
    }
    try {
      final image = await event.downloadAndDecryptAttachment(
        getThumbnail: true,
      );
      if (image.bytes.isEmpty || image.bytes.length > 10 * 1024 * 1024) {
        return null;
      }
      final directory = await getTemporaryDirectory();
      final extension = path.extension(image.name).toLowerCase();
      final safeExtension = RegExp(r'^\.[a-z0-9]{1,5}$').hasMatch(extension)
          ? extension
          : '.jpg';
      final file = File(
        path.join(
          directory.path,
          'patrick-message-${event.eventId.hashCode & 0x7fffffff}$safeExtension',
        ),
      );
      await file.writeAsBytes(image.bytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  bool _remember(String eventId) {
    if (!_recentEventIdSet.add(eventId)) return false;
    _recentEventIds.addLast(eventId);
    while (_recentEventIds.length > 200) {
      _recentEventIdSet.remove(_recentEventIds.removeFirst());
    }
    return true;
  }

  Future<void> dispose() async {
    await _timelineSubscription?.cancel();
    await _decryptedTimelineSubscription?.cancel();
    await _inviteSubscription?.cancel();
    await _syncSubscription?.cancel();
    await _loginSubscription?.cancel();
  }
}

/// Whether a decrypted live timeline event represents a new user-visible
/// message that should produce a local notification.
///
/// Synapse includes `unsigned.transaction_id` only for the access-token
/// session that sent an event. That lets us suppress a notification on the
/// exact device that sent a message while retaining notifications on a second
/// phone, tablet, or desktop logged into the same Matrix account.
bool shouldNotifyForTimelineEvent({
  required bool timelineReady,
  required String eventType,
  required String? relationshipType,
  required String senderId,
  required String? ownUserId,
  required String? transactionId,
}) {
  if (!timelineReady) return false;
  if (relationshipType == controlRelationType) return false;
  if (relationshipType == RelationshipTypes.edit) return false;
  if (senderId == ownUserId && transactionId != null) return false;
  return eventType == EventTypes.Message || eventType == EventTypes.Sticker;
}

/// Whether a local alert should be discarded because another client advanced
/// the account's fully-read marker to this event or a newer one.
bool shouldSuppressNotificationForReadMarker({
  required bool notifyIfReadElsewhere,
  required String eventId,
  required DateTime eventTimestamp,
  required String fullyReadEventId,
  required DateTime? fullyReadTimestamp,
}) {
  if (notifyIfReadElsewhere || fullyReadEventId.isEmpty) return false;
  if (fullyReadEventId == eventId) return true;
  return fullyReadTimestamp != null &&
      !fullyReadTimestamp.isBefore(eventTimestamp);
}

String notificationPreview(Event event) {
  final preview = switch (event.messageType) {
    MessageTypes.Image => 'Sent a picture',
    MessageTypes.Sticker => 'Sent a sticker',
    MessageTypes.File => 'Sent a file',
    MessageTypes.Audio => 'Sent an audio message',
    MessageTypes.Video => 'Sent a video',
    MessageTypes.Location => 'Shared a location',
    MessageTypes.BadEncrypted => 'New encrypted message',
    _ => event.calcUnlocalizedBody(
      hideReply: true,
      hideEdit: true,
      plaintextBody: true,
    ),
  };
  final oneLine = preview.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (oneLine.isEmpty) return 'New message';
  return oneLine.length <= 180 ? oneLine : '${oneLine.substring(0, 177)}…';
}
