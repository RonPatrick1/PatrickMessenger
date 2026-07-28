import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:share_plus/share_plus.dart' as sharing;

import '../archive/archive_contract.dart';
import '../archive/archive_models.dart';
import '../archive/archive_repository.dart';
import '../export/conversation_export_service.dart';
import '../history/timeline_key_recovery.dart';
import '../matrix/display_names.dart';
import '../matrix/timeline_event_merge.dart';
import '../notifications/liam_chatter_visibility.dart';
import '../receipts/message_receipt_service.dart';
import '../search/search_index_service.dart';
import '../search/shared_search_service.dart';
import '../services/chat_clipboard.dart';
import '../services/giphy_client.dart';
import '../settings/text_scale_preference.dart';
import 'chat/chat_composer.dart';
import 'chat/archive_message_bubble.dart';
import 'chat/emoji_picker_dialog.dart';
import 'chat/emoji_style.dart';
import 'chat/giphy_picker_dialog.dart';
import 'chat/message_action_dialog.dart';
import 'chat/message_bubble.dart';
import 'chat/message_interactions.dart';
import 'chat/rename_conversation_dialog.dart';
import 'chat/typing_indicator.dart';
import 'search_screen.dart';

class ChatScreen extends StatefulWidget {
  final Room room;
  final String giphyApiKey;
  final String liamUserId;
  final TextScalePreferenceController textScaleController;
  final LiamChatterVisibilityController liamChatterVisibility;
  final ArchiveRoomData archive;
  final SearchIndexService searchIndex;
  final MessageReceiptService receiptService;
  final MessageSearchResult? initialSearchResult;

  const ChatScreen({
    required this.room,
    required this.giphyApiKey,
    required this.liamUserId,
    required this.textScaleController,
    required this.liamChatterVisibility,
    required this.archive,
    required this.searchIndex,
    required this.receiptService,
    this.initialSearchResult,
    super.key,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  static const _initialMatrixMessageCount = 50;
  static const _initialArchiveMessageCount = 200;
  static const _archiveHistoryPageSize = 200;

  final TextEditingController _messageController =
      ColorEmojiTextEditingController(emojiTextStyle: emojiGlyphStyle());
  final _messageFocusNode = FocusNode();
  final _itemScrollController = ItemScrollController();
  final _itemPositions = ItemPositionsListener.create();
  final _selectedEventIds = <String>{};
  final _liveTimelineEvents = <String, Event>{};

  Timeline? _timeline;
  Event? _replyTo;
  Event? _editingEvent;
  ArchiveMessage? _archiveReplyTo;
  ArchiveMessage? _editingArchiveMessage;
  bool _sendingAttachment = false;
  bool _invitingLiam = false;
  bool _loadingHistory = false;
  bool _loadingSearchResult = false;
  bool _changingSharedSearch = false;
  SharedSearchProgress? _sharedSearchProgress;
  bool _exportingConversation = false;
  ConversationExportProgress? _exportProgress;
  final Map<int, Offset> _textScalePointers = <int, Offset>{};
  double? _pinchStartTextScale;
  double? _pinchStartDistance;
  bool _showJumpToLatest = false;
  List<User> _typingUsers = [];
  StreamSubscription<SyncUpdate>? _typingSubscription;
  StreamSubscription<Event>? _timelineEventSubscription;
  Timer? _timelineRefreshTimer;
  DateTime? _lastTypingNoticeSentAt;
  String? _highlightMessageId;
  bool _didJumpToInitialResult = false;
  int _visibleItemCount = 0;
  int _visibleArchiveMessageCount = _initialArchiveMessageCount;
  List<ArchiveMessage> _archiveMessages = const [];

  bool get _selectionMode => _selectedEventIds.isNotEmpty;
  bool get _liamJoined => widget.room
      .getParticipants(const [Membership.join])
      .any((user) => user.id == widget.liamUserId);
  bool get _sharedSearchJoined =>
      widget.searchIndex.sharedSearch.isJoined(widget.room);

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleHardwareKeyboard);
    _itemPositions.itemPositions.addListener(_handleScroll);
    _messageController.addListener(_handleComposerTextChanged);
    _typingSubscription = widget.room.client.onSync.stream.listen(
      (_) => _refreshTypingUsers(),
    );
    widget.liamChatterVisibility.addListener(_handlePreferencesChanged);
    widget.archive.addListener(_handleArchiveChanged);
    _archiveMessages = widget.archive.messages;
    unawaited(
      widget.archive.loadRecent().then((_) {
        if (!mounted) return;
        final initialResult = widget.initialSearchResult;
        if (initialResult?.sourceKind == SearchSourceKind.archive) {
          unawaited(_scrollToSearchResult(initialResult!));
        }
      }),
    );
    widget.room.getTimeline(onUpdate: _handleTimelineUpdate).then((timeline) {
      if (!mounted) {
        timeline.cancelSubscriptions();
        return;
      }
      setState(() => _timeline = timeline);
      _timelineEventSubscription = widget.room.client.onTimelineEvent.stream
          .where((event) => event.roomId == widget.room.id)
          .listen(_handleLiveTimelineEvent);
      unawaited(widget.searchIndex.indexTimeline(timeline));
      _markLatestMessageRead();
      unawaited(_prepareInitialTimeline(timeline));
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleHardwareKeyboard);
    _timelineRefreshTimer?.cancel();
    _timelineEventSubscription?.cancel();
    _timeline?.cancelSubscriptions();
    _typingSubscription?.cancel();
    widget.liamChatterVisibility.removeListener(_handlePreferencesChanged);
    widget.archive.removeListener(_handleArchiveChanged);
    _itemPositions.itemPositions.removeListener(_handleScroll);
    _messageController.removeListener(_handleComposerTextChanged);
    _messageController.dispose();
    _messageFocusNode.dispose();
    super.dispose();
  }

  void _handleTimelineUpdate() {
    if (!mounted) return;
    setState(() {});
    _markLatestMessageRead();
  }

  void _scheduleTimelineRefresh() {
    _timelineRefreshTimer?.cancel();
    // Timeline events are broadcast before all asynchronous decryption and
    // aggregation work has necessarily completed. Rebuild just after that
    // work settles so a message cannot remain in the timeline/database while
    // the already-open chat window stays stale.
    _timelineRefreshTimer = Timer(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      setState(() {});
      _markLatestMessageRead();
    });
  }

  void _handleLiveTimelineEvent(Event event) {
    _liveTimelineEvents[event.eventId] = event;
    // Bound the fallback cache for conversations that stay open for days.
    while (_liveTimelineEvents.length > 250) {
      _liveTimelineEvents.remove(_liveTimelineEvents.keys.first);
    }
    _scheduleTimelineRefresh();
  }

  Future<void> _prepareInitialTimeline(Timeline timeline) async {
    if (_messages(timeline).length < _initialMatrixMessageCount &&
        timeline.canRequestHistory) {
      if (mounted) setState(() => _loadingHistory = true);
      try {
        // Shared Search uses encrypted custom events in the conversation for
        // indexing and queries. Those events are intentionally hidden from
        // the chat, but a burst of them can fill Matrix's initial timeline
        // page and push every real message outside the loaded window.
        for (var page = 0; page < 20; page++) {
          if (!mounted || !identical(_timeline, timeline)) return;
          if (_messages(timeline).length >= _initialMatrixMessageCount ||
              !timeline.canRequestHistory) {
            break;
          }
          final previousEventCount = timeline.events.length;
          await timeline.requestHistory(historyCount: 100);
          if (timeline.events.length == previousEventCount) break;
        }
      } catch (_) {
        // The normal manual history control remains available if automatic
        // pagination is interrupted by a temporary network failure.
      } finally {
        if (mounted && identical(_timeline, timeline)) {
          setState(() => _loadingHistory = false);
        }
      }
    }

    await _recoverVisibleHistoryKeys(timeline);
    if (!mounted || !identical(_timeline, timeline)) return;
    final initialResult = widget.initialSearchResult;
    if (initialResult != null) {
      await _scrollToSearchResult(initialResult);
    }
  }

  void _handlePreferencesChanged() {
    if (mounted) setState(() {});
  }

  void _handleArchiveChanged() {
    if (!mounted) return;
    unawaited(widget.searchIndex.indexArchiveRoom(widget.archive));
    final messages = widget.archive.messages;
    setState(() => _archiveMessages = messages);
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
    final liamTyping = _typingUsers.any((user) => user.id == widget.liamUserId);
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
    if (_visibleItemCount == 0) return;
    final positions = _itemPositions.itemPositions.value;
    if (positions.isEmpty) return;

    final showJumpToLatest = positions.every((position) => position.index != 0);
    if (showJumpToLatest != _showJumpToLatest && mounted) {
      setState(() => _showJumpToLatest = showJumpToLatest);
    }

    if (!_loadingHistory &&
        positions.map((position) => position.index).reduce(max) >=
            _visibleItemCount - 3) {
      unawaited(_loadMoreHistory());
    }
  }

  bool _handleHardwareKeyboard(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.end ||
        (!HardwareKeyboard.instance.isControlPressed &&
            !HardwareKeyboard.instance.isMetaPressed)) {
      return false;
    }
    _jumpToLatest();
    return true;
  }

  void _jumpToLatest() {
    if (!_itemScrollController.isAttached || _visibleItemCount == 0) return;
    _itemScrollController.jumpTo(index: 0);
    if (_showJumpToLatest && mounted) {
      setState(() => _showJumpToLatest = false);
    }
  }

  bool _hasOlderMessages(Timeline timeline) =>
      timeline.canRequestHistory ||
      _visibleArchiveMessageCount < _archiveMessages.length ||
      widget.archive.canLoadOlder;

  Future<void> _loadMoreHistory() async {
    final timeline = _timeline;
    if (timeline == null || _loadingHistory || !_hasOlderMessages(timeline)) {
      return;
    }

    final requestMatrixHistory = timeline.canRequestHistory;
    final targetArchiveCount =
        _visibleArchiveMessageCount + _archiveHistoryPageSize;
    final requestArchiveHistory =
        widget.archive.canLoadOlder &&
        targetArchiveCount > _archiveMessages.length;
    setState(() => _loadingHistory = true);
    try {
      await Future.wait([
        if (requestMatrixHistory) timeline.requestHistory(historyCount: 100),
        if (requestArchiveHistory) widget.archive.loadOlder(),
      ]);
      if (requestMatrixHistory) {
        await _recoverVisibleHistoryKeys(timeline);
      }
      if (mounted) {
        setState(() {
          _visibleArchiveMessageCount = min(
            _archiveMessages.length,
            targetArchiveCount,
          );
        });
      }
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
    // Matrix normally inserts live events into Timeline before onUpdate. On
    // iOS we have observed the client-wide event stream advancing while an
    // already-open Timeline remains stale. Overlay those live events by event
    // or transaction identity so local echoes do not duplicate synced events.
    final visibleEvents = mergeMatrixTimelineEvents(
      timelineEvents: timeline.events,
      liveEvents: _liveTimelineEvents.values,
    );
    return visibleEvents
        .where(
          (event) =>
              event.type == EventTypes.Message &&
              event.relationshipType != RelationshipTypes.edit &&
              (!hideLiamChatter ||
                  !isLiamChatterEvent(event, liamUserId: widget.liamUserId)),
        )
        .toList();
  }

  List<_ChatItem> _chatItems(Timeline timeline) {
    final items = <_ChatItem>[
      ..._messages(timeline).map(_ChatItem.matrix),
      ..._archiveMessages
          .take(_visibleArchiveMessageCount)
          .map(_ChatItem.archive),
    ];
    items.sort((a, b) {
      final time = b.timestamp.compareTo(a.timestamp);
      return time != 0 ? time : b.id.compareTo(a.id);
    });
    return items;
  }

  void _scheduleJumpToResult(List<_ChatItem> items) {
    final result = widget.initialSearchResult;
    if (_didJumpToInitialResult || result == null) return;
    final index = items.indexWhere((item) => item.id == result.sourceId);
    if (index < 0) return;
    _didJumpToInitialResult = true;
    _highlightMessageId = result.sourceId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_itemScrollController.isAttached) return;
      _itemScrollController.jumpTo(index: index);
      Future<void>.delayed(const Duration(seconds: 3), () {
        if (mounted) setState(() => _highlightMessageId = null);
      });
    });
  }

  Future<void> _openSearch() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MessageSearchScreen(
          client: widget.room.client,
          searchIndex: widget.searchIndex,
          roomId: widget.room.id,
          openResult: (result) async {
            Navigator.of(context).pop();
            await _scrollToSearchResult(result);
          },
        ),
      ),
    );
  }

  Future<void> _scrollToSearchResult(MessageSearchResult result) async {
    final timeline = _timeline;
    if (timeline == null || _loadingSearchResult) return;
    _loadingSearchResult = true;
    try {
      if (result.sourceKind == SearchSourceKind.archive) {
        await widget.archive.loadUntilMessage(result.sourceId);
        if (!mounted) return;
        final archiveMessages = widget.archive.messages;
        final archiveIndex = archiveMessages.indexWhere(
          (message) => message.id == result.sourceId,
        );
        if (archiveIndex >= 0) {
          setState(() {
            _archiveMessages = archiveMessages;
            _visibleArchiveMessageCount = max(
              _visibleArchiveMessageCount,
              archiveIndex + 1,
            );
          });
        }
      }
      var items = _chatItems(timeline);
      if (result.sourceKind == SearchSourceKind.matrix &&
          !items.any((item) => item.id == result.sourceId)) {
        if (mounted) setState(() => _loadingHistory = true);
        while (timeline.canRequestHistory &&
            !timeline.events.any((event) => event.eventId == result.sourceId)) {
          await timeline.requestHistory(historyCount: 250);
        }
        await _recoverVisibleHistoryKeys(timeline);
        items = _chatItems(timeline);
      }
      final index = items.indexWhere((item) => item.id == result.sourceId);
      if (index < 0 || !mounted) {
        if (mounted) _showError('That search result could not be loaded.');
        return;
      }
      _didJumpToInitialResult = true;
      setState(() => _highlightMessageId = result.sourceId);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_itemScrollController.isAttached) return;
        _itemScrollController.scrollTo(
          index: index,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOut,
        );
        Future<void>.delayed(const Duration(seconds: 3), () {
          if (mounted) setState(() => _highlightMessageId = null);
        });
      });
    } catch (_) {
      if (mounted) _showError('That search result could not be loaded.');
    } finally {
      _loadingSearchResult = false;
      if (mounted && _loadingHistory) setState(() => _loadingHistory = false);
    }
  }

  int _hiddenLiamChatterCount(Timeline timeline) {
    if (!widget.liamChatterVisibility.isHidden(widget.room.id)) return 0;
    return timeline.events
        .where(
          (event) =>
              event.type == EventTypes.Message &&
              event.relationshipType != RelationshipTypes.edit &&
              isLiamChatterEvent(event, liamUserId: widget.liamUserId),
        )
        .length;
  }

  int _undecryptableEventCount(Timeline timeline) => mergeMatrixTimelineEvents(
    timelineEvents: timeline.events,
    liveEvents: _liveTimelineEvents.values,
  ).where(isUndecryptableEvent).length;

  void _markLatestMessageRead() {
    final timeline = _timeline;
    if (timeline == null) return;
    final messages = _messages(timeline);
    if (messages.isEmpty) return;
    final latest = messages.where((event) => event.status.isSent).firstOrNull;
    if (latest == null) return;
    unawaited(_setReadMarker(latest.eventId));
    unawaited(widget.receiptService.markRead(messages.take(100)));
  }

  Future<void> _setReadMarker(String eventId) async {
    try {
      await widget.room.setReadMarker(
        eventId,
        mRead: eventId,
        public: widget.receiptService.preferences.enabled,
      );
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
    final editingArchiveMessage = _editingArchiveMessage;
    final archiveReplyTo = _archiveReplyTo;
    final liamQuestion = editingEvent == null && editingArchiveMessage == null
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
      if (editingArchiveMessage != null) {
        await widget.archive.edit(editingArchiveMessage.id, message);
      } else if (editingEvent != null) {
        await widget.room.sendTextEvent(
          message,
          editEventId: editingEvent.eventId,
        );
      } else {
        final content = <String, dynamic>{
          'msgtype': MessageTypes.Text,
          'body': message,
          messageRecipientsKey: _receiptRecipients(),
          if (archiveReplyTo != null) archiveReplyKey: archiveReplyTo.id,
          if (liamQuestion != null && _relationRootEventId().isNotEmpty)
            'm.relates_to': {
              'rel_type': liamChatterRelationType,
              'event_id': _relationRootEventId(),
            },
        };
        await widget.room.sendEvent(
          content,
          inReplyTo: liamQuestion == null ? replyTo : null,
        );
      }
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
        _archiveReplyTo = archiveReplyTo;
        _editingArchiveMessage = editingArchiveMessage;
      });
    }
  }

  List<String> _receiptRecipients() => widget.room
      .getParticipants(const [Membership.join])
      .map((user) => user.id)
      .where(
        (id) =>
            id != widget.room.client.userID &&
            id != widget.liamUserId &&
            id != widget.searchIndex.sharedSearch.searchUserId,
      )
      .toList(growable: false);

  String _relationRootEventId() => widget.room.lastEvent?.eventId ?? '';

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
      case AttachmentKind.addSharedSearch:
        await _addSharedSearch();
      case AttachmentKind.rebuildSharedSearch:
        await _rebuildSharedSearch();
      case AttachmentKind.removeSharedSearch:
        await _removeSharedSearch();
      case AttachmentKind.picture:
        await _sendPicture();
      case AttachmentKind.pastePicture:
        await _pasteFromClipboard();
      case AttachmentKind.gifSearch:
        await _searchAndSendGif();
    }
  }

  void _prepareLiamQuestion() {
    if (_editingEvent != null || _editingArchiveMessage != null) {
      _messageController.clear();
      setState(() {
        _editingEvent = null;
        _editingArchiveMessage = null;
      });
    }
    _messageController.value = withLiamPrefix(_messageController.value);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _messageFocusNode.requestFocus();
    });
  }

  Future<void> _removeLiam() async {
    if (!_liamJoined) return;
    try {
      await widget.room.sendEvent({
        'msgtype': MessageTypes.Text,
        'body': liamLeaveCommand,
        messageRecipientsKey: _receiptRecipients(),
        if (_relationRootEventId().isNotEmpty)
          'm.relates_to': {
            'rel_type': liamChatterRelationType,
            'event_id': _relationRootEventId(),
          },
      });
    } catch (_) {
      if (mounted) _showError('Liam could not be removed right now.');
    }
  }

  Future<void> _addSharedSearch() async {
    if (_changingSharedSearch) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add shared search?'),
        content: const Text(
          'Search will join this encrypted conversation as a service account. '
          'It will receive an encrypted copy of the existing searchable '
          'history and can decrypt new messages while it remains a member. '
          'Its stored index contains keyed token hashes and message IDs, not '
          'message text or pictures. Any room member can remove it later, but '
          'removal cannot undo access it already had while it was a member.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Add and index'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (widget.room.name.isEmpty) {
      try {
        await widget.room.setName(readableMatrixRoomName(widget.room));
      } catch (_) {
        // Shared search still works when the current account cannot preserve
        // the calculated room title as an explicit title.
      }
    }
    await _runSharedSearchBackfill();
  }

  Future<void> _rebuildSharedSearch() async {
    if (_changingSharedSearch || !_sharedSearchJoined) return;
    await _runSharedSearchBackfill();
  }

  Future<void> _runSharedSearchBackfill() async {
    setState(() {
      _changingSharedSearch = true;
      _sharedSearchProgress = const SharedSearchProgress(
        phase: SharedSearchPhase.inviting,
        completed: 0,
        total: 0,
        message: 'Adding Search to this encrypted conversation…',
      );
    });
    try {
      final count = await widget.searchIndex.sharedSearch.addAndBackfill(
        room: widget.room,
        archive: widget.archive,
        onProgress: (progress) {
          if (mounted) setState(() => _sharedSearchProgress = progress);
        },
      );
      await widget.searchIndex.removeLocalRoom(widget.room.id);
      if (mounted) {
        setState(() {});
        _showStatus('Shared search is ready with $count indexed messages.');
      }
    } catch (_) {
      if (mounted) {
        _showError(
          'Shared search could not be completed. Check that the Search '
          'service is running, then try again.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _changingSharedSearch = false;
          _sharedSearchProgress = null;
        });
      }
    }
  }

  Future<void> _removeSharedSearch() async {
    if (_changingSharedSearch || !_sharedSearchJoined) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove shared search?'),
        content: const Text(
          'Search will delete this conversation’s shared index and leave the '
          'room. Searches will return to this device’s private local index.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _changingSharedSearch = true);
    try {
      await widget.searchIndex.sharedSearch.remove(widget.room);
      if (mounted) {
        _showStatus('Search is deleting this chat’s shared index and leaving.');
      }
    } catch (_) {
      if (mounted) _showError('Shared search could not be removed right now.');
    } finally {
      if (mounted) setState(() => _changingSharedSearch = false);
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

  bool _isTextScalePointer(PointerEvent event) =>
      event.kind == PointerDeviceKind.touch ||
      event.kind == PointerDeviceKind.stylus;

  void _handleTextScalePointerDown(PointerDownEvent event) {
    if (!_isTextScalePointer(event)) return;
    if (_textScalePointers.length >= 2) return;
    _textScalePointers[event.pointer] = event.position;
    if (_textScalePointers.length == 2) {
      _beginTextPinch();
    }
  }

  void _handleTextScalePointerMove(PointerMoveEvent event) {
    if (!_textScalePointers.containsKey(event.pointer)) return;
    _textScalePointers[event.pointer] = event.position;
    if (_textScalePointers.length < 2) return;
    _pinchStartDistance ??= _currentTextPinchDistance();
    _pinchStartTextScale ??= widget.textScaleController.scale;
    final startDistance = _pinchStartDistance!;
    if (startDistance <= 0) return;
    widget.textScaleController.previewScale(
      _pinchStartTextScale! * (_currentTextPinchDistance() / startDistance),
    );
  }

  void _handleTextScalePointerEnd(PointerEvent event) {
    if (!_textScalePointers.containsKey(event.pointer)) return;
    _textScalePointers.remove(event.pointer);
    if (_textScalePointers.length >= 2 || _pinchStartTextScale == null) return;
    _pinchStartTextScale = null;
    _pinchStartDistance = null;
    unawaited(widget.textScaleController.persistScale());
  }

  void _beginTextPinch() {
    _pinchStartTextScale = widget.textScaleController.scale;
    _pinchStartDistance = _currentTextPinchDistance();
  }

  double _currentTextPinchDistance() {
    final points = _textScalePointers.values.take(2).toList();
    if (points.length < 2) return 0;
    return (points.first - points.last).distance;
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
        extraContent: {
          messageRecipientsKey: _receiptRecipients(),
          archiveReplyKey: ?_archiveReplyTo?.id,
        },
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
        extraContent: {
          messageRecipientsKey: _receiptRecipients(),
          if (_archiveReplyTo != null) archiveReplyKey: _archiveReplyTo!.id,
        },
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
      _archiveReplyTo = null;
      _editingArchiveMessage = null;
    });
  }

  void _startReply(Event event) {
    setState(() {
      _replyTo = event;
      _editingEvent = null;
      _archiveReplyTo = null;
      _editingArchiveMessage = null;
    });
  }

  void _startArchiveReply(ArchiveMessage message) {
    setState(() {
      _archiveReplyTo = message;
      _editingArchiveMessage = null;
      _replyTo = null;
      _editingEvent = null;
    });
  }

  void _startArchiveEdit(ArchiveMessage message) {
    setState(() {
      _editingArchiveMessage = message;
      _archiveReplyTo = null;
      _editingEvent = null;
      _replyTo = null;
      _messageController.text = message.body;
      _messageController.selection = TextSelection.collapsed(
        offset: message.body.length,
      );
    });
  }

  void _startEdit(Event event, Timeline timeline) {
    final displayEvent = event.getDisplayEvent(timeline);
    setState(() {
      _editingEvent = event;
      _replyTo = null;
      _archiveReplyTo = null;
      _editingArchiveMessage = null;
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

  Future<void> _openArchiveMessageActions(ArchiveMessage message) async {
    final mine = message.authorMatrixId == widget.room.client.userID;
    final action = await showModalBottomSheet<_ArchiveAction>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.add_reaction_outlined),
              title: const Text('React'),
              onTap: () => Navigator.pop(sheetContext, _ArchiveAction.react),
            ),
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Reply'),
              onTap: () => Navigator.pop(sheetContext, _ArchiveAction.reply),
            ),
            if (mine && message.body.isNotEmpty && !message.deleted)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: () => Navigator.pop(sheetContext, _ArchiveAction.edit),
              ),
            if (message.body.isNotEmpty && !message.deleted)
              ListTile(
                leading: const Icon(Icons.content_copy_outlined),
                title: const Text('Copy text'),
                onTap: () => Navigator.pop(sheetContext, _ArchiveAction.copy),
              ),
            ListTile(
              leading: const Icon(Icons.forward_outlined),
              title: const Text('Forward'),
              onTap: () => Navigator.pop(sheetContext, _ArchiveAction.forward),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Info'),
              onTap: () => Navigator.pop(sheetContext, _ArchiveAction.info),
            ),
            if (mine && !message.deleted)
              ListTile(
                leading: Icon(
                  Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  'Delete for everyone',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                onTap: () => Navigator.pop(sheetContext, _ArchiveAction.delete),
              ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _ArchiveAction.react:
        final emoji = await pickReactionEmoji(context);
        if (emoji != null) {
          await widget.archive.toggleReaction(message.id, emoji);
        }
      case _ArchiveAction.reply:
        _startArchiveReply(message);
      case _ArchiveAction.edit:
        _startArchiveEdit(message);
      case _ArchiveAction.copy:
        await Clipboard.setData(ClipboardData(text: message.body));
        if (mounted) _showStatus('Copied to clipboard.');
      case _ArchiveAction.forward:
        await _forwardArchiveMessage(message);
      case _ArchiveAction.info:
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Imported message information'),
            content: SelectionArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _InfoRow(label: 'From', value: message.authorName),
                  _InfoRow(
                    label: 'Sent',
                    value: message.timestamp.toLocal().toString(),
                  ),
                  _InfoRow(label: 'Source', value: 'Signal history import'),
                  _InfoRow(label: 'Archive ID', value: message.id),
                ],
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
      case _ArchiveAction.delete:
        await widget.archive.delete(message.id);
    }
  }

  Future<void> _forwardArchiveMessage(ArchiveMessage message) async {
    final target = await _chooseForwardRoom();
    if (target == null) return;
    try {
      if (message.body.isNotEmpty) await target.sendTextEvent(message.body);
      for (final attachment in message.attachments.where(
        (item) => !item.missing,
      )) {
        final bytes = await widget.archive.loadAttachment(attachment);
        if (attachment.isImage) {
          final image = await MatrixImageFile.create(
            bytes: bytes,
            name: attachment.name,
            mimeType: attachment.mimeType,
            nativeImplementations: target.client.nativeImplementations,
          );
          await target.sendFileEvent(image);
        } else {
          await target.sendFileEvent(
            MatrixFile(
              bytes: bytes,
              name: attachment.name,
              mimeType: attachment.mimeType,
            ),
          );
        }
      }
      if (mounted) _showStatus('Forwarded securely.');
    } catch (_) {
      if (mounted) _showError('The imported message could not be forwarded.');
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

  Future<void> _exportConversation() async {
    if (_exportingConversation) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Export decrypted conversation?'),
        content: const Text(
          'The ZIP will contain the complete message history this device can '
          'decrypt, plus every available picture and attachment. The exported '
          'copy is not end-to-end encrypted. Anyone who gets the ZIP can read '
          'it, so keep it somewhere private and protected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Export'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final fileName = ConversationExportService.suggestedFileName(widget.room);
    final desktop = Platform.isLinux || Platform.isMacOS || Platform.isWindows;
    String? destinationPath;
    if (desktop) {
      final location = await getSaveLocation(
        suggestedName: fileName,
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'ZIP archives',
            extensions: ['zip'],
            mimeTypes: ['application/zip'],
            uniformTypeIdentifiers: ['public.zip-archive'],
          ),
        ],
      );
      destinationPath = location?.path;
      if (destinationPath == null || !mounted) return;
      if (path.extension(destinationPath).toLowerCase() != '.zip') {
        destinationPath = '$destinationPath.zip';
      }
    } else {
      final temporaryDirectory = await getTemporaryDirectory();
      destinationPath = path.join(
        temporaryDirectory.path,
        'patrick_messenger_exports',
        fileName,
      );
    }

    setState(() {
      _exportingConversation = true;
      _exportProgress = const ConversationExportProgress(
        phase: ConversationExportPhase.loadingHistory,
        completed: 0,
        total: 0,
        message: 'Loading the complete encrypted conversation…',
      );
    });

    try {
      final result = await ConversationExportService().export(
        room: widget.room,
        importedArchive: widget.archive,
        destinationPath: destinationPath,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _exportProgress = progress);
        },
      );
      if (!mounted) return;

      if (!desktop) {
        final renderBox = context.findRenderObject() as RenderBox?;
        await sharing.SharePlus.instance.share(
          sharing.ShareParams(
            title: 'Patrick Messenger conversation export',
            text: 'Decrypted conversation export from Patrick Messenger.',
            files: [XFile(result.path, mimeType: 'application/zip')],
            fileNameOverrides: [fileName],
            sharePositionOrigin: renderBox == null
                ? null
                : renderBox.localToGlobal(Offset.zero) & renderBox.size,
          ),
        );
      }
      if (!mounted) return;
      final warnings = [
        if (result.missingMediaCount > 0)
          '${result.missingMediaCount} unavailable attachment(s)',
        if (result.undecryptableCount > 0)
          '${result.undecryptableCount} message(s) this device could not decrypt',
      ];
      _showStatus(
        desktop
            ? 'Exported ${result.messageCount} messages to ${result.path}'
            : warnings.isEmpty
            ? 'Exported ${result.messageCount} messages.'
            : 'Exported ${result.messageCount} messages; ${warnings.join(', ')}.',
      );
    } catch (_) {
      if (mounted) {
        _showError(
          'The conversation could not be exported. Check the connection and '
          'available storage, then try again.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _exportingConversation = false;
          _exportProgress = null;
        });
      }
    }
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
    final messages = timeline == null
        ? const <_ChatItem>[]
        : _chatItems(timeline);
    _visibleItemCount = messages.length;
    _scheduleJumpToResult(messages);
    final selected = timeline == null
        ? const <Event>[]
        : _selectedEvents(timeline);
    final contextEvent = _editingEvent ?? _replyTo;
    final hiddenLiamCount = timeline == null
        ? 0
        : _hiddenLiamChatterCount(timeline);
    final undecryptableEventCount = timeline == null
        ? 0
        : _undecryptableEventCount(timeline);

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
                  onPressed: _openSearch,
                  tooltip: 'Search this conversation',
                  icon: const Icon(Icons.search),
                ),
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
                  onPressed: _openSearch,
                  tooltip: 'Search this conversation',
                  icon: const Icon(Icons.search),
                ),
                IconButton(
                  onPressed: _exportingConversation
                      ? null
                      : _exportConversation,
                  tooltip: 'Export conversation',
                  icon: _exportingConversation
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_outlined),
                ),
                IconButton(
                  onPressed: _toggleLiamChatterHidden,
                  tooltip: widget.liamChatterVisibility.isHidden(widget.room.id)
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
          : Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _handleTextScalePointerDown,
              onPointerMove: _handleTextScalePointerMove,
              onPointerUp: _handleTextScalePointerEnd,
              onPointerCancel: _handleTextScalePointerEnd,
              child: Column(
                children: [
                  if (_sharedSearchProgress case final progress?)
                    Material(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              progress.message,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 6),
                            LinearProgressIndicator(value: progress.fraction),
                          ],
                        ),
                      ),
                    ),
                  if (_exportProgress case final progress?)
                    Material(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              progress.message,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 6),
                            LinearProgressIndicator(value: progress.fraction),
                          ],
                        ),
                      ),
                    ),
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: messages.isEmpty
                              ? const _EmptyConversation()
                              : ScrollablePositionedList.builder(
                                  itemScrollController: _itemScrollController,
                                  itemPositionsListener: _itemPositions,
                                  reverse: true,
                                  padding: const EdgeInsets.fromLTRB(
                                    14,
                                    12,
                                    14,
                                    18,
                                  ),
                                  itemCount:
                                      messages.length +
                                      (_hasOlderMessages(timeline) ? 1 : 0),
                                  itemBuilder: (context, index) {
                                    if (index == messages.length) {
                                      return Center(
                                        child: Padding(
                                          padding: const EdgeInsets.all(12),
                                          child: _loadingHistory
                                              ? const CircularProgressIndicator()
                                              : TextButton.icon(
                                                  onPressed: _loadMoreHistory,
                                                  icon: const Icon(
                                                    Icons.history,
                                                  ),
                                                  label: const Text(
                                                    'Load older messages',
                                                  ),
                                                ),
                                        ),
                                      );
                                    }
                                    final item = messages[index];
                                    final archiveMessage = item.archiveMessage;
                                    if (archiveMessage != null) {
                                      return AnimatedContainer(
                                        duration: const Duration(
                                          milliseconds: 250,
                                        ),
                                        color: _highlightMessageId == item.id
                                            ? Theme.of(context)
                                                  .colorScheme
                                                  .tertiaryContainer
                                                  .withValues(alpha: 0.35)
                                            : Colors.transparent,
                                        child: ArchiveMessageBubble(
                                          key: ValueKey(item.id),
                                          message: archiveMessage,
                                          archive: widget.archive,
                                          mine:
                                              archiveMessage.authorMatrixId ==
                                              widget.room.client.userID,
                                          onOpenActions: () =>
                                              _openArchiveMessageActions(
                                                archiveMessage,
                                              ),
                                          onReaction: (emoji) =>
                                              widget.archive.toggleReaction(
                                                archiveMessage.id,
                                                emoji,
                                              ),
                                        ),
                                      );
                                    }
                                    final event = item.event!;
                                    final actionsEnabled =
                                        !isUndecryptableEvent(event);
                                    return AnimatedContainer(
                                      duration: const Duration(
                                        milliseconds: 250,
                                      ),
                                      color: _highlightMessageId == item.id
                                          ? Theme.of(context)
                                                .colorScheme
                                                .tertiaryContainer
                                                .withValues(alpha: 0.35)
                                          : Colors.transparent,
                                      child: MessageBubble(
                                        key: ValueKey(event.eventId),
                                        event: event,
                                        timeline: timeline,
                                        mine:
                                            event.senderId ==
                                            widget.room.client.userID,
                                        selectionMode: _selectionMode,
                                        selected: _selectedEventIds.contains(
                                          event.eventId,
                                        ),
                                        pinned: widget.room.pinnedEventIds
                                            .contains(event.eventId),
                                        actionsEnabled: actionsEnabled,
                                        liamUserId: widget.liamUserId,
                                        receiptService: widget.receiptService,
                                        archive: widget.archive,
                                        onOpenActions: () =>
                                            _openMessageActions(event),
                                        onSelectionTap: () =>
                                            _toggleSelected(event),
                                        onReaction: (emoji) =>
                                            _toggleReaction(event, emoji),
                                      ),
                                    );
                                  },
                                ),
                        ),
                        if (_showJumpToLatest)
                          Positioned(
                            right: 16,
                            bottom: 12,
                            child: IconButton.filledTonal(
                              onPressed: _jumpToLatest,
                              tooltip: 'Jump to latest message',
                              icon: const Icon(Icons.keyboard_arrow_down),
                            ),
                          ),
                      ],
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
                  if (undecryptableEventCount > 0 && !_selectionMode)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: Text(
                        undecryptableEventCount == 1
                            ? '1 encrypted item is waiting for its key'
                            : '$undecryptableEventCount encrypted items are '
                                  'waiting for their keys',
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
                      sendingAttachment:
                          _sendingAttachment || _changingSharedSearch,
                      liamJoined: _liamJoined,
                      sharedSearchJoined: _sharedSearchJoined,
                      contextLabel:
                          _editingEvent != null ||
                              _editingArchiveMessage != null
                          ? 'Editing message'
                          : _replyTo != null
                          ? 'Replying to ${readableMatrixUserName(_replyTo!.senderFromMemoryOrFallback)}'
                          : _archiveReplyTo != null
                          ? 'Replying to ${_archiveReplyTo!.authorName}'
                          : null,
                      contextPreview:
                          _editingArchiveMessage?.body ??
                          _archiveReplyTo?.body ??
                          (contextEvent == null
                              ? null
                              : visibleMessageBody(
                                  contextEvent.getDisplayEvent(timeline),
                                )),
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
            ),
    );
  }
}

enum _ArchiveAction { react, reply, edit, copy, forward, info, delete }

class _ChatItem {
  final Event? event;
  final ArchiveMessage? archiveMessage;

  const _ChatItem._({this.event, this.archiveMessage});

  factory _ChatItem.matrix(Event event) => _ChatItem._(event: event);
  factory _ChatItem.archive(ArchiveMessage message) =>
      _ChatItem._(archiveMessage: message);

  String get id => event?.eventId ?? archiveMessage!.id;
  DateTime get timestamp => event?.originServerTs ?? archiveMessage!.timestamp;
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
