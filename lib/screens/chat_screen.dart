import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:matrix/matrix.dart';

import '../history/timeline_key_recovery.dart';
import '../matrix/display_names.dart';
import '../notifications/liam_chatter_visibility.dart';
import '../services/chat_clipboard.dart';
import '../services/giphy_client.dart';
import '../settings/text_scale_preference.dart';
import 'chat/chat_composer.dart';
import 'chat/emoji_picker_dialog.dart';
import 'chat/giphy_picker_dialog.dart';
import 'chat/message_action_dialog.dart';
import 'chat/message_bubble.dart';
import 'chat/message_interactions.dart';
import 'chat/rename_conversation_dialog.dart';
import 'chat/typing_indicator.dart';

class ChatScreen extends StatefulWidget {
  final Room room;
  final String giphyApiKey;
  final String liamUserId;
  final TextScalePreferenceController textScaleController;
  final LiamChatterVisibilityController liamChatterVisibility;

  const ChatScreen({
    required this.room,
    required this.giphyApiKey,
    required this.liamUserId,
    required this.textScaleController,
    required this.liamChatterVisibility,
    super.key,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _messageController = TextEditingController();
  final _messageFocusNode = FocusNode();
  final _scrollController = ScrollController();
  final _selectedEventIds = <String>{};

  Timeline? _timeline;
  Event? _replyTo;
  Event? _editingEvent;
  bool _sendingAttachment = false;
  bool _invitingLiam = false;
  bool _loadingHistory = false;
  double? _pinchStartTextScale;
  List<User> _typingUsers = [];
  StreamSubscription<SyncUpdate>? _typingSubscription;
  DateTime? _lastTypingNoticeSentAt;

  bool get _selectionMode => _selectedEventIds.isNotEmpty;
  bool get _liamJoined => widget.room
      .getParticipants(const [Membership.join])
      .any((user) => user.id == widget.liamUserId);

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    _messageController.addListener(_handleComposerTextChanged);
    _typingSubscription = widget.room.client.onSync.stream.listen(
      (_) => _refreshTypingUsers(),
    );
    widget.liamChatterVisibility.addListener(_handlePreferencesChanged);
    widget.room
        .getTimeline(
          onUpdate: () {
            if (!mounted) return;
            setState(() {});
            _markLatestMessageRead();
          },
        )
        .then((timeline) {
          if (!mounted) {
            timeline.cancelSubscriptions();
            return;
          }
          setState(() => _timeline = timeline);
          _markLatestMessageRead();
          unawaited(_recoverVisibleHistoryKeys(timeline));
        });
  }

  @override
  void dispose() {
    _timeline?.cancelSubscriptions();
    _typingSubscription?.cancel();
    widget.liamChatterVisibility.removeListener(_handlePreferencesChanged);
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    _messageController.removeListener(_handleComposerTextChanged);
    _messageController.dispose();
    _messageFocusNode.dispose();
    super.dispose();
  }

  void _handlePreferencesChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _toggleLiamChatterHidden() async {
    final hidden = widget.liamChatterVisibility.isHidden(widget.room.id);
    await widget.liamChatterVisibility.setHidden(widget.room.id, !hidden);
  }

  void _refreshTypingUsers() {
    if (!mounted) return;
    final ownUserId = widget.room.client.userID;
    final updated = widget.room.typingUsers
        .where((user) => user.id != ownUserId)
        .toList();
    final updatedIds = (updated.map((u) => u.id).toList()..sort()).join(',');
    final currentIds = (_typingUsers.map((u) => u.id).toList()..sort()).join(
      ',',
    );
    if (updatedIds != currentIds) setState(() => _typingUsers = updated);
  }

  void _handleComposerTextChanged() {
    final composing = _messageController.text.trim().isNotEmpty;
    if (composing) {
      final now = DateTime.now();
      final last = _lastTypingNoticeSentAt;
      if (last == null || now.difference(last) > const Duration(seconds: 4)) {
        _lastTypingNoticeSentAt = now;
        unawaited(widget.room.setTyping(true, timeout: 8000));
      }
    } else if (_lastTypingNoticeSentAt != null) {
      _lastTypingNoticeSentAt = null;
      unawaited(widget.room.setTyping(false));
    }
  }

  String _typingLabel() {
    final liamTyping = _typingUsers.any(
      (user) => user.id == widget.liamUserId,
    );
    final otherNames = _typingUsers
        .where((user) => user.id != widget.liamUserId)
        .map(readableMatrixUserName)
        .toList();
    return typingIndicatorLabel(
      otherTypingNames: otherNames,
      liamTyping: liamTyping,
    );
  }

  void _handleScroll() {
    if (!_scrollController.hasClients || _loadingHistory) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 320) {
      unawaited(_loadMoreHistory());
    }
  }

  Future<void> _loadMoreHistory() async {
    final timeline = _timeline;
    if (timeline == null || _loadingHistory || !timeline.canRequestHistory) {
      return;
    }
    setState(() => _loadingHistory = true);
    try {
      await timeline.requestHistory(historyCount: 100);
      await _recoverVisibleHistoryKeys(timeline);
    } catch (_) {
      if (mounted) _showError('Older messages could not be downloaded.');
    } finally {
      if (mounted) setState(() => _loadingHistory = false);
    }
  }

  Future<void> _recoverVisibleHistoryKeys(Timeline timeline) async {
    try {
      await recoverTimelineKeys(timeline);
      if (!mounted || !identical(_timeline, timeline)) return;
      setState(() {});
    } catch (_) {
      // Missing historical keys are handled by the manual History Sync
      // screen. They must never interrupt an active conversation.
    }
  }

  List<Event> _messages(Timeline timeline) {
    final hideLiamChatter = widget.liamChatterVisibility.isHidden(
      widget.room.id,
    );
    return timeline.events
        .where(
          (event) =>
              (event.type == EventTypes.Message ||
                  isUndecryptableEvent(event)) &&
              event.relationshipType != RelationshipTypes.edit &&
              (!hideLiamChatter ||
                  !isLiamChatterEvent(event, liamUserId: widget.liamUserId)),
        )
        .toList();
  }

  int _hiddenLiamChatterCount(Timeline timeline) {
    if (!widget.liamChatterVisibility.isHidden(widget.room.id)) return 0;
    return timeline.events
        .where(
          (event) =>
              (event.type == EventTypes.Message ||
                  isUndecryptableEvent(event)) &&
              event.relationshipType != RelationshipTypes.edit &&
              isLiamChatterEvent(event, liamUserId: widget.liamUserId),
        )
        .length;
  }

  void _markLatestMessageRead() {
    final timeline = _timeline;
    if (timeline == null) return;
    final messages = _messages(timeline);
    if (messages.isEmpty) return;
    final latest = messages.where((event) => event.status.isSent).firstOrNull;
    if (latest == null) return;
    unawaited(_setReadMarker(latest.eventId));
  }

  Future<void> _setReadMarker(String eventId) async {
    try {
      await widget.room.setReadMarker(eventId, mRead: eventId, public: false);
    } catch (_) {
      // A timeline event can disappear during a sync race. The next timeline
      // update will retry with the latest server-confirmed event.
    }
  }

  Future<void> _sendText() async {
    final message = _messageController.text.trim();
    if (message.isEmpty) return;

    final replyTo = _replyTo;
    final editingEvent = _editingEvent;
    final liamQuestion = editingEvent == null
        ? extractLiamQuestion(message)
        : null;
    if (liamQuestion != null) {
      if (liamQuestion.isEmpty) {
        _showError('Write a question after "Liam:".');
        return;
      }
      if (!await _ensureLiamJoined()) return;
    }

    _messageController.clear();
    _lastTypingNoticeSentAt = null;
    unawaited(widget.room.setTyping(false));
    _cancelComposerContext();
    try {
      await widget.room.sendTextEvent(
        message,
        inReplyTo: editingEvent == null ? replyTo : null,
        editEventId: editingEvent?.eventId,
      );
    } catch (_) {
      if (!mounted) return;
      _showError(
        editingEvent == null
            ? 'The message could not be sent.'
            : 'The edit could not be saved.',
      );
      _messageController.text = message;
      setState(() {
        _replyTo = replyTo;
        _editingEvent = editingEvent;
      });
    }
  }

  Future<bool> _ensureLiamJoined() async {
    if (_liamJoined) return true;
    if (_invitingLiam) {
      return _waitForLiamJoin();
    }

    setState(() => _invitingLiam = true);
    try {
      final participants = await widget.room.requestParticipants(const [
        Membership.join,
        Membership.invite,
      ], true);
      if (participants.any(
        (user) =>
            user.id == widget.liamUserId && user.membership == Membership.join,
      )) {
        return true;
      }

      final alreadyInvited = participants.any(
        (user) =>
            user.id == widget.liamUserId &&
            user.membership == Membership.invite,
      );
      if (!alreadyInvited) {
        await widget.room.invite(
          widget.liamUserId,
          reason: 'A room member asked Liam a question.',
        );
      }

      final joined = await _waitForLiamJoin();
      if (!joined && mounted) {
        _showError(
          'Liam was invited but has not joined yet. Try sending again in a moment.',
        );
      }
      return joined;
    } catch (_) {
      if (mounted) {
        _showError('Liam could not be added to this conversation.');
      }
      return false;
    } finally {
      if (mounted) setState(() => _invitingLiam = false);
    }
  }

  Future<bool> _waitForLiamJoin() async {
    for (var attempt = 0; attempt < 80; attempt++) {
      if (_liamJoined) return true;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!mounted) return false;
    }
    return _liamJoined;
  }

  Future<void> _sendAttachment(AttachmentKind kind) async {
    switch (kind) {
      case AttachmentKind.askLiam:
        _prepareLiamQuestion();
      case AttachmentKind.removeLiam:
        await _removeLiam();
      case AttachmentKind.picture:
        await _sendPicture();
      case AttachmentKind.pastePicture:
        await _pasteFromClipboard();
      case AttachmentKind.gifSearch:
        await _searchAndSendGif();
    }
  }

  void _prepareLiamQuestion() {
    if (_editingEvent != null) {
      _messageController.clear();
      setState(() => _editingEvent = null);
    }
    _messageController.value = withLiamPrefix(_messageController.value);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _messageFocusNode.requestFocus();
    });
  }

  Future<void> _removeLiam() async {
    if (!_liamJoined) return;
    try {
      await widget.room.sendTextEvent(liamLeaveCommand);
    } catch (_) {
      if (mounted) _showError('Liam could not be removed right now.');
    }
  }

  Future<void> _sendPicture() async {
    if (_sendingAttachment) return;
    const imageTypes = XTypeGroup(
      label: 'Pictures',
      extensions: <String>[
        'avif',
        'bmp',
        'gif',
        'heic',
        'heif',
        'jpeg',
        'jpg',
        'png',
        'webp',
      ],
      mimeTypes: <String>['image/*'],
      uniformTypeIdentifiers: <String>['public.image'],
      webWildCards: <String>['image/*'],
    );
    final selectedFile = defaultTargetPlatform == TargetPlatform.iOS
        ? await ImagePicker().pickImage(
            source: ImageSource.gallery,
            requestFullMetadata: false,
          )
        : await openFile(acceptedTypeGroups: const <XTypeGroup>[imageTypes]);
    if (selectedFile == null) return;

    const maximumBytes = 25 * 1024 * 1024;
    if (await selectedFile.length() > maximumBytes) {
      _showError('Choose a file smaller than 25 MB.');
      return;
    }

    try {
      await _sendImageBytes(
        bytes: await selectedFile.readAsBytes(),
        name: selectedFile.name,
        mimeType: selectedFile.mimeType,
      );
    } catch (_) {
      if (mounted) _showError('The selected picture could not be read.');
    }
  }

  Future<void> _takePicture() async {
    if (_sendingAttachment) return;
    try {
      final picture = await ImagePicker().pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
        requestFullMetadata: false,
        imageQuality: 92,
        maxWidth: 2400,
        maxHeight: 2400,
      );
      if (picture == null) return;
      await _sendImageBytes(
        bytes: await picture.readAsBytes(),
        name: picture.name,
        mimeType: picture.mimeType,
      );
    } catch (_) {
      if (mounted) _showError('The camera could not take a picture.');
    }
  }

  void _startTextPinch(ScaleStartDetails details) {
    if (details.pointerCount >= 2) {
      _pinchStartTextScale = widget.textScaleController.scale;
    }
  }

  void _updateTextPinch(ScaleUpdateDetails details) {
    if (details.pointerCount < 2) return;
    _pinchStartTextScale ??= widget.textScaleController.scale;
    widget.textScaleController.previewScale(
      _pinchStartTextScale! * details.scale,
    );
  }

  void _finishTextPinch(ScaleEndDetails details) {
    if (_pinchStartTextScale == null) return;
    _pinchStartTextScale = null;
    unawaited(widget.textScaleController.persistScale());
  }

  Future<void> _pasteFromClipboard() async {
    if (_sendingAttachment) return;
    try {
      final contents = await ChatClipboard().read();
      final image = contents.image;
      if (image != null) {
        await _sendImageBytes(
          bytes: image.bytes,
          name: image.filename,
          mimeType: image.mimeType,
        );
        return;
      }
      final text = contents.text;
      if (text != null && text.isNotEmpty) {
        _insertComposerText(text);
        return;
      }
      _showError('The clipboard does not contain a picture or text.');
    } on FormatException catch (error) {
      _showError(error.message.toString());
    } catch (_) {
      _showError('The clipboard picture could not be read.');
    }
  }

  void _insertComposerText(String text) {
    final value = _messageController.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final start = selection.start.clamp(0, value.text.length);
    final end = selection.end.clamp(0, value.text.length);
    _messageController.value = value.copyWith(
      text: value.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
      composing: TextRange.empty,
    );
  }

  Future<void> _sendImageBytes({
    required Uint8List bytes,
    required String name,
    String? mimeType,
  }) async {
    if (_sendingAttachment) return;
    if (bytes.length > ChatClipboard.maximumImageBytes) {
      _showError('Choose a file smaller than 25 MB.');
      return;
    }

    setState(() => _sendingAttachment = true);
    try {
      final image = await MatrixImageFile.create(
        bytes: bytes,
        name: name,
        mimeType: mimeType,
        nativeImplementations: widget.room.client.nativeImplementations,
      );
      final preserveAnimation =
          isAnimatedGifName(name) || image.mimeType == 'image/gif';
      await widget.room.sendFileEvent(
        image,
        inReplyTo: _replyTo,
        shrinkImageMaxDimension: preserveAnimation ? null : 1600,
      );
      if (mounted) _cancelComposerContext();
    } catch (_) {
      if (mounted) {
        _showError('The picture could not be encrypted and sent.');
      }
    } finally {
      if (mounted) setState(() => _sendingAttachment = false);
    }
  }

  Future<void> _searchAndSendGif() async {
    if (_sendingAttachment) return;
    final giphy = GiphyClient(apiKey: widget.giphyApiKey);
    try {
      final gif = await showGiphyPickerDialog(context: context, client: giphy);
      if (gif == null || !mounted) return;

      setState(() => _sendingAttachment = true);
      _showStatus('Downloading and encrypting GIF…');
      final bytes = await giphy.download(gif);
      final image = await MatrixImageFile.create(
        bytes: bytes,
        name: gif.filename,
        mimeType: 'image/gif',
        nativeImplementations: widget.room.client.nativeImplementations,
      );
      await widget.room.sendFileEvent(
        image,
        inReplyTo: _replyTo,
        shrinkImageMaxDimension: null,
      );
      if (mounted) _cancelComposerContext();
    } on GiphyException catch (error) {
      if (mounted) _showError(error.message);
    } catch (_) {
      if (mounted) _showError('The GIF could not be encrypted and sent.');
    } finally {
      giphy.close();
      if (mounted) setState(() => _sendingAttachment = false);
    }
  }

  void _cancelComposerContext() {
    if (!mounted) return;
    setState(() {
      _replyTo = null;
      _editingEvent = null;
    });
  }

  void _startReply(Event event) {
    setState(() {
      _replyTo = event;
      _editingEvent = null;
    });
  }

  void _startEdit(Event event, Timeline timeline) {
    final displayEvent = event.getDisplayEvent(timeline);
    setState(() {
      _editingEvent = event;
      _replyTo = null;
      _messageController.text = visibleMessageBody(displayEvent);
      _messageController.selection = TextSelection.collapsed(
        offset: _messageController.text.length,
      );
    });
  }

  Future<void> _openMessageActions(Event event) async {
    final timeline = _timeline;
    if (timeline == null) return;
    final displayEvent = event.getDisplayEvent(timeline);
    final result = await showMessageActionDialog(
      context: context,
      event: event,
      mine: event.senderId == widget.room.client.userID,
      isText: isTextMessage(displayEvent),
      isPinned: widget.room.pinnedEventIds.contains(event.eventId),
    );
    if (!mounted || result == null) return;

    if (result is SelectedReaction) {
      await _toggleReaction(event, result.emoji);
      return;
    }

    final action = (result as SelectedMessageAction).action;
    switch (action) {
      case MessageAction.reactMore:
        final emoji = await pickReactionEmoji(context);
        if (emoji != null && mounted) await _toggleReaction(event, emoji);
      case MessageAction.reply:
        _startReply(event);
      case MessageAction.edit:
        _startEdit(event, timeline);
      case MessageAction.copy:
        await _copyEvents([event]);
      case MessageAction.forward:
        await _forwardEvents([event]);
      case MessageAction.select:
        _toggleSelected(event);
      case MessageAction.pin:
        await _togglePinned(event);
      case MessageAction.info:
        await _showMessageInfo(event, timeline);
      case MessageAction.resend:
        await _resendEvent(event);
      case MessageAction.cancelSend:
        await _cancelSendEvent(event);
      case MessageAction.delete:
        await _deleteEvents([event]);
    }
  }

  Future<void> _resendEvent(Event event) async {
    try {
      await event.sendAgain();
    } catch (_) {
      if (mounted) _showError('The message could not be resent.');
    }
  }

  Future<void> _cancelSendEvent(Event event) async {
    try {
      await event.cancelSend();
    } catch (_) {
      if (mounted) _showError('The message could not be removed.');
    }
  }

  Future<void> _toggleReaction(Event event, String emoji) async {
    final timeline = _timeline;
    if (timeline == null) return;
    final ownReaction = event
        .aggregatedEvents(timeline, RelationshipTypes.reaction)
        .where(
          (reaction) =>
              reaction.senderId == widget.room.client.userID &&
              reactionKeyFromContent(reaction.content) == emoji &&
              !reaction.redacted,
        )
        .firstOrNull;
    try {
      if (ownReaction == null) {
        await widget.room.sendReaction(event.eventId, emoji);
      } else {
        await ownReaction.redactEvent(reason: 'Reaction removed');
      }
    } catch (_) {
      if (mounted) _showError('The reaction could not be updated.');
    }
  }

  Future<void> _togglePinned(Event event) async {
    final pinned = [...widget.room.pinnedEventIds];
    final wasPinned = pinned.remove(event.eventId);
    if (!wasPinned) pinned.add(event.eventId);
    try {
      await widget.room.setPinnedEvents(pinned);
      if (mounted) {
        setState(() {});
        _showStatus(wasPinned ? 'Message unpinned.' : 'Message pinned.');
      }
    } catch (_) {
      if (mounted) {
        _showError(
          'This account does not have permission to change room pins.',
        );
      }
    }
  }

  Future<void> _copyEvents(List<Event> events) async {
    final timeline = _timeline;
    if (timeline == null) return;
    final text = events
        .where((event) => isTextMessage(event.getDisplayEvent(timeline)))
        .map((event) => visibleMessageBody(event.getDisplayEvent(timeline)))
        .join('\n');
    if (text.isEmpty) {
      _showError('Only text messages can be copied.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) _showStatus('Copied to clipboard.');
  }

  Future<void> _forwardEvents(List<Event> events) async {
    final timeline = _timeline;
    if (timeline == null) return;
    final target = await _chooseForwardRoom();
    if (target == null || !mounted) return;

    _showStatus('Forwarding ${events.length} message(s)…');
    try {
      for (final event in events) {
        await _forwardEvent(event, timeline, target);
      }
      if (mounted) _showStatus('Forwarded securely.');
    } catch (_) {
      if (mounted) _showError('One or more messages could not be forwarded.');
    }
  }

  Future<Room?> _chooseForwardRoom() {
    final rooms = widget.room.client.rooms
        .where(
          (room) =>
              room.id != widget.room.id &&
              room.membership == Membership.join &&
              room.encrypted,
        )
        .toList();
    if (rooms.isEmpty) {
      _showError('There is no other encrypted conversation to forward to.');
      return Future.value(null);
    }
    return showDialog<Room>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Forward to'),
        children: [
          for (final room in rooms)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, room),
              child: ListTile(
                leading: const Icon(Icons.lock_outline),
                title: Text(readableMatrixRoomName(room)),
                contentPadding: EdgeInsets.zero,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _forwardEvent(
    Event event,
    Timeline timeline,
    Room target,
  ) async {
    final displayEvent = event.getDisplayEvent(timeline);
    if (isTextMessage(displayEvent)) {
      await target.sendTextEvent(visibleMessageBody(displayEvent));
      return;
    }

    if (displayEvent.messageType == MessageTypes.Image ||
        displayEvent.messageType == MessageTypes.Sticker) {
      final downloaded = await displayEvent.downloadAndDecryptAttachment();
      final image = await MatrixImageFile.create(
        bytes: downloaded.bytes,
        name: downloaded.name,
        mimeType: downloaded.mimeType,
        nativeImplementations: target.client.nativeImplementations,
      );
      await target.sendFileEvent(
        image,
        shrinkImageMaxDimension:
            image.mimeType == 'image/gif' || isAnimatedGifName(image.name)
            ? null
            : 1600,
      );
      return;
    }

    final downloaded = await displayEvent.downloadAndDecryptAttachment();
    await target.sendFileEvent(
      MatrixFile(
        bytes: downloaded.bytes,
        name: downloaded.name,
        mimeType: downloaded.mimeType,
      ),
    );
  }

  Future<void> _showMessageInfo(Event event, Timeline timeline) {
    final displayEvent = event.getDisplayEvent(timeline);
    final sender = readableMatrixUserName(event.senderFromMemoryOrFallback);
    final receipts = event.receipts
        .where((receipt) => receipt.user.id != widget.room.client.userID)
        .map((receipt) => readableMatrixUserName(receipt.user))
        .join(', ');
    final edited = event.hasAggregatedEvents(timeline, RelationshipTypes.edit);
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.info_outline),
        title: const Text('Message information'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SelectionArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _InfoRow(label: 'From', value: '$sender\n${event.senderId}'),
                _InfoRow(
                  label: 'Sent',
                  value: event.originServerTs.toLocal().toString(),
                ),
                _InfoRow(label: 'Type', value: displayEvent.messageType),
                _InfoRow(
                  label: 'Encrypted',
                  value: widget.room.encrypted ? 'Yes' : 'No',
                ),
                _InfoRow(label: 'Edited', value: edited ? 'Yes' : 'No'),
                _InfoRow(
                  label: 'Pinned',
                  value: widget.room.pinnedEventIds.contains(event.eventId)
                      ? 'Yes'
                      : 'No',
                ),
                _InfoRow(
                  label: 'Read by',
                  value: receipts.isEmpty ? 'No public receipt yet' : receipts,
                ),
                _InfoRow(label: 'Event ID', value: event.eventId),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteEvents(List<Event> events) async {
    final deletable = events.where((event) => event.canRedact).toList();
    if (deletable.isEmpty) {
      _showError('You cannot delete the selected messages.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: Text(
          deletable.length == 1
              ? 'Delete this message?'
              : 'Delete ${deletable.length} messages?',
        ),
        content: const Text(
          'This removes the content for everyone in the conversation.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete for everyone'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      for (final event in deletable) {
        await event.redactEvent(reason: 'Deleted by sender');
      }
      if (mounted) {
        _clearSelection();
        _showStatus('Message content deleted.');
      }
    } catch (_) {
      if (mounted) _showError('The message could not be deleted.');
    }
  }

  void _toggleSelected(Event event) {
    setState(() {
      if (!_selectedEventIds.add(event.eventId)) {
        _selectedEventIds.remove(event.eventId);
      }
    });
  }

  void _clearSelection() {
    if (!mounted) return;
    setState(_selectedEventIds.clear);
  }

  List<Event> _selectedEvents(Timeline timeline) {
    return _messages(timeline)
        .where((event) => _selectedEventIds.contains(event.eventId))
        .toList()
        .reversed
        .toList();
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showStatus(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _renameConversation() async {
    final currentName = widget.room.name.isNotEmpty
        ? widget.room.name
        : readableMatrixRoomName(widget.room);
    final newName = await showRenameConversationDialog(
      context: context,
      initialName: currentName,
    );
    if (newName == null || newName == currentName || !mounted) return;

    try {
      await widget.room.setName(newName);
      if (mounted) {
        setState(() {});
        _showStatus('Conversation renamed.');
      }
    } catch (_) {
      if (mounted) {
        _showError(
          'This account cannot rename the conversation yet. Open the updated '
          'app once using the account that originally created this '
          'conversation, then try again.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final timeline = _timeline;
    final messages = timeline == null ? const <Event>[] : _messages(timeline);
    final selected = timeline == null
        ? const <Event>[]
        : _selectedEvents(timeline);
    final contextEvent = _editingEvent ?? _replyTo;
    final hiddenLiamCount = timeline == null
        ? 0
        : _hiddenLiamChatterCount(timeline);

    return Scaffold(
      appBar: _selectionMode
          ? AppBar(
              leading: IconButton(
                onPressed: _clearSelection,
                tooltip: 'Cancel selection',
                icon: const Icon(Icons.close),
              ),
              title: Text('${_selectedEventIds.length} selected'),
              actions: [
                IconButton(
                  onPressed: () => _copyEvents(selected),
                  tooltip: 'Copy text',
                  icon: const Icon(Icons.content_copy_outlined),
                ),
                IconButton(
                  onPressed: () => _forwardEvents(selected),
                  tooltip: 'Forward',
                  icon: const Icon(Icons.forward_outlined),
                ),
                IconButton(
                  onPressed: selected.any((event) => event.canRedact)
                      ? () => _deleteEvents(selected)
                      : null,
                  tooltip: 'Delete for everyone',
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            )
          : AppBar(
              titleSpacing: 0,
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    readableMatrixRoomName(widget.room),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.lock, size: 12),
                      SizedBox(width: 4),
                      Text(
                        'End-to-end encrypted',
                        style: TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                ],
              ),
              actions: [
                IconButton(
                  onPressed: _toggleLiamChatterHidden,
                  tooltip: widget.liamChatterVisibility.isHidden(
                    widget.room.id,
                  )
                      ? 'Show Liam chatter in this conversation'
                      : 'Hide Liam chatter in this conversation',
                  icon: Icon(
                    widget.liamChatterVisibility.isHidden(widget.room.id)
                        ? Icons.smart_toy
                        : Icons.smart_toy_outlined,
                  ),
                ),
                IconButton(
                  onPressed: _renameConversation,
                  tooltip: 'Rename conversation',
                  icon: const Icon(Icons.edit_outlined),
                ),
              ],
            ),
      body: timeline == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onScaleStart: _startTextPinch,
                    onScaleUpdate: _updateTextPinch,
                    onScaleEnd: _finishTextPinch,
                    child: messages.isEmpty
                        ? const _EmptyConversation()
                        : ListView.builder(
                            controller: _scrollController,
                            reverse: true,
                            padding: const EdgeInsets.fromLTRB(14, 12, 14, 18),
                            itemCount:
                                messages.length +
                                (timeline.canRequestHistory ? 1 : 0),
                            itemBuilder: (context, index) {
                              if (index == messages.length) {
                                return Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: _loadingHistory
                                        ? const CircularProgressIndicator()
                                        : TextButton.icon(
                                            onPressed: _loadMoreHistory,
                                            icon: const Icon(Icons.history),
                                            label: const Text(
                                              'Load older messages',
                                            ),
                                          ),
                                  ),
                                );
                              }
                              final event = messages[index];
                              final actionsEnabled = !isUndecryptableEvent(
                                event,
                              );
                              return MessageBubble(
                                key: ValueKey(event.eventId),
                                event: event,
                                timeline: timeline,
                                mine:
                                    event.senderId == widget.room.client.userID,
                                selectionMode: _selectionMode,
                                selected: _selectedEventIds.contains(
                                  event.eventId,
                                ),
                                pinned: widget.room.pinnedEventIds.contains(
                                  event.eventId,
                                ),
                                actionsEnabled: actionsEnabled,
                                liamUserId: widget.liamUserId,
                                onOpenActions: () => _openMessageActions(event),
                                onSelectionTap: () => _toggleSelected(event),
                                onReaction: (emoji) =>
                                    _toggleReaction(event, emoji),
                              );
                            },
                          ),
                  ),
                ),
                if (hiddenLiamCount > 0 && !_selectionMode)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Text(
                      hiddenLiamCount == 1
                          ? '1 Liam message hidden'
                          : '$hiddenLiamCount Liam messages hidden',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (_typingUsers.isNotEmpty && !_selectionMode)
                  TypingIndicatorBar(label: _typingLabel()),
                if (!_selectionMode)
                  ChatComposer(
                    controller: _messageController,
                    focusNode: _messageFocusNode,
                    sendingAttachment: _sendingAttachment,
                    liamJoined: _liamJoined,
                    contextLabel: _editingEvent != null
                        ? 'Editing message'
                        : _replyTo != null
                        ? 'Replying to ${readableMatrixUserName(_replyTo!.senderFromMemoryOrFallback)}'
                        : null,
                    contextPreview: contextEvent == null
                        ? null
                        : visibleMessageBody(
                            contextEvent.getDisplayEvent(timeline),
                          ),
                    onCancelContext: _cancelComposerContext,
                    onSend: _sendText,
                    onPaste: _pasteFromClipboard,
                    onEmoji: () =>
                        showComposerEmojiPicker(context, _messageController),
                    onCamera: _takePicture,
                    onAttachment: _sendAttachment,
                  ),
              ],
            ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(value),
        ],
      ),
    );
  }
}

class _EmptyConversation extends StatelessWidget {
  const _EmptyConversation();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(28),
        child: Text(
          'This conversation is end-to-end encrypted.\n'
          'Send the first message, picture, GIF, or emoji.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
