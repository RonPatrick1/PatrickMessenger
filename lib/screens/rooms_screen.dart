import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as path;
import 'package:share_receiver/share_receiver.dart';

import '../config/app_config.dart';
import '../archive/archive_repository.dart';
import '../matrix/display_names.dart';
import '../matrix/room_rename_permissions.dart';
import '../notifications/conversation_mute_controller.dart';
import '../notifications/liam_chatter_visibility.dart';
import '../notifications/message_notification_service.dart';
import '../notifications/notification_preferences.dart';
import '../receipts/message_receipt_service.dart';
import '../receipts/read_receipt_preferences.dart';
import '../search/search_index_service.dart';
import '../sharing/incoming_share_controller.dart';
import '../settings/text_scale_preference.dart';
import '../settings/theme_preference.dart';
import 'chat_screen.dart';
import 'chat/emoji_style.dart';
import 'history_recovery_dialog.dart';
import 'new_conversation_dialog.dart';
import 'profile_dialog.dart';
import 'search_screen.dart';

class RoomsScreen extends StatelessWidget {
  final Client client;
  final AppConfig config;
  final ThemePreferenceController themeController;
  final TextScalePreferenceController textScaleController;
  final NotificationPreferenceController notificationController;
  final MessageNotificationService notificationService;
  final ConversationMuteController conversationMuteController;
  final LiamChatterVisibilityController liamChatterVisibility;
  final ArchiveRepository archives;
  final SearchIndexService searchIndex;
  final ReadReceiptPreferenceController readReceiptController;
  final MessageReceiptService receiptService;
  final IncomingShareController incomingShares;

  const RoomsScreen({
    required this.client,
    required this.config,
    required this.themeController,
    required this.textScaleController,
    required this.notificationController,
    required this.notificationService,
    required this.conversationMuteController,
    required this.liamChatterVisibility,
    required this.archives,
    required this.searchIndex,
    required this.readReceiptController,
    required this.receiptService,
    required this.incomingShares,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    RoomRenamePermissionUpgrader.schedule(client);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Messages'),
        actions: [
          IconButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => MessageSearchScreen(
                  client: client,
                  searchIndex: searchIndex,
                  openResult: (result) => _openSearchResult(context, result),
                ),
              ),
            ),
            tooltip: 'Search all conversations',
            icon: const Icon(Icons.search),
          ),
          ThemePreferenceMenuButton(controller: themeController),
          IconButton(
            onPressed: () =>
                showHistoryRecoveryDialog(context: context, client: client),
            tooltip: 'Encrypted history sync',
            icon: const Icon(Icons.cloud_sync_outlined),
          ),
          IconButton(
            onPressed: () => _showSecurityInfo(context),
            tooltip: 'Security status',
            icon: const Icon(Icons.shield_outlined),
          ),
          PopupMenuButton<_AccountAction>(
            onSelected: (action) async {
              switch (action) {
                case _AccountAction.settings:
                  await showAccountSettingsDialog(
                    context: context,
                    client: client,
                    notificationController: notificationController,
                    notificationService: notificationService,
                    readReceiptController: readReceiptController,
                    searchIndex: searchIndex,
                  );
                case _AccountAction.signOut:
                  await client.logout();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _AccountAction.settings,
                child: ListTile(
                  leading: Icon(Icons.manage_accounts_outlined),
                  title: Text('Account settings'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: _AccountAction.signOut,
                child: ListTile(
                  leading: Icon(Icons.logout),
                  title: Text('Sign out'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _startConversation(context),
        icon: const Icon(Icons.edit_outlined),
        label: const Text('New message'),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              HistoryRecoveryBanner(client: client),
              Expanded(
                child: ListenableBuilder(
                  listenable: conversationMuteController,
                  builder: (context, _) => StreamBuilder<SyncUpdate>(
                    stream: client.onSync.stream,
                    builder: (context, _) {
                      RoomRenamePermissionUpgrader.schedule(client);
                      final rooms = client.rooms
                          .where(
                            (room) =>
                                room.membership == Membership.join ||
                                room.membership == Membership.invite,
                          )
                          .toList();

                      if (rooms.isEmpty) {
                        return _EmptyRooms(
                          onStart: () => _startConversation(context),
                        );
                      }

                      return ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
                        itemCount: rooms.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 4),
                        itemBuilder: (context, index) {
                          final room = rooms[index];
                          return _RoomTile(
                            room: room,
                            muted: conversationMuteController.isMuted(room.id),
                            onTap: () => _openRoom(context, room),
                            onToggleMute: () =>
                                _toggleConversationMute(context, room),
                            onAddPerson: () =>
                                _addPersonToConversation(context, room),
                            onDelete: () => _deleteConversation(context, room),
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
          _IncomingSharePrompt(
            controller: incomingShares,
            client: client,
            onSelected: (room, share) =>
                _openRoom(context, room, incomingShare: share),
          ),
        ],
      ),
    );
  }

  Future<void> _openRoom(
    BuildContext context,
    Room room, {
    MessageSearchResult? initialResult,
    SharedData? incomingShare,
  }) async {
    if (room.membership == Membership.invite) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Accept invitation?'),
          content: Text(
            '${readableMatrixInviterName(room)} invited you to an encrypted '
            'conversation. Join it?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Join'),
            ),
          ],
        ),
      );
      if (accepted != true) return;
      try {
        await room.join();
      } catch (_) {
        if (context.mounted) {
          _showError(context, 'The invitation could not be accepted.');
        }
        return;
      }
    }

    await room.postLoad();
    if (!room.encrypted) {
      if (context.mounted) {
        _showError(
          context,
          'This room is not end-to-end encrypted, so this client will not '
          'open it.',
        );
      }
      return;
    }
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(
          room: room,
          config: config,
          giphyApiKey: config.giphyApiKey,
          liamUserId: config.liamUserId,
          textScaleController: textScaleController,
          liamChatterVisibility: liamChatterVisibility,
          archive: archives.forRoom(room),
          searchIndex: searchIndex,
          receiptService: receiptService,
          initialSearchResult: initialResult,
          initialShare: incomingShare,
        ),
      ),
    );
  }

  Future<void> _openSearchResult(
    BuildContext searchContext,
    MessageSearchResult result,
  ) async {
    final room = client.getRoomById(result.roomId);
    if (room == null) return;
    Navigator.of(searchContext).pop();
    await _openRoom(searchContext, room, initialResult: result);
  }

  Future<void> _startConversation(BuildContext context) async {
    final result = await showDialog<NewConversationResult>(
      context: context,
      builder: (_) => NewConversationDialog(client: client, config: config),
    );
    if (result == null || result.recipients.isEmpty || !context.mounted) {
      return;
    }

    if (result.recipients.length == 1) {
      await _startDirectConversation(context, result.recipients.single);
      return;
    }
    await _startGroupConversation(context, result);
  }

  Future<void> _startDirectConversation(
    BuildContext context,
    Profile profile,
  ) async {
    final matrixId = profile.userId;
    final messenger = ScaffoldMessenger.of(context);

    for (final room in client.rooms) {
      if ((room.membership == Membership.join ||
              room.membership == Membership.invite) &&
          room.directChatMatrixID == matrixId) {
        await _openRoom(context, room);
        return;
      }
    }

    messenger.showSnackBar(
      const SnackBar(content: Text('Creating an encrypted conversation…')),
    );
    try {
      final roomId = await client.createGroupChat(
        invite: [matrixId],
        enableEncryption: true,
        federated: false,
        historyVisibility: HistoryVisibility.invited,
        powerLevelContentOverride: {
          'events': {EventTypes.RoomName: 0},
        },
      );
      final room = client.getRoomById(roomId);
      if (room == null) throw StateError('Room was not returned by sync.');
      await room.addToDirectChat(matrixId);
      if (context.mounted) await _openRoom(context, room);
    } catch (_) {
      if (context.mounted) {
        _showError(context, 'The encrypted conversation could not be created.');
      }
    }
  }

  Future<void> _startGroupConversation(
    BuildContext context,
    NewConversationResult result,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Creating an encrypted group…')),
    );
    try {
      final roomId = await client.createGroupChat(
        invite: [for (final profile in result.recipients) profile.userId],
        groupName: result.groupName,
        enableEncryption: true,
        federated: false,
        historyVisibility: HistoryVisibility.invited,
        powerLevelContentOverride: {
          'events': {EventTypes.RoomName: 0},
        },
      );
      final room = client.getRoomById(roomId);
      if (room == null) throw StateError('Room was not returned by sync.');
      if (context.mounted) await _openRoom(context, room);
    } catch (_) {
      if (context.mounted) {
        _showError(context, 'The encrypted group could not be created.');
      }
    }
  }

  Future<void> _addPersonToConversation(BuildContext context, Room room) async {
    final result = await showDialog<NewConversationResult>(
      context: context,
      builder: (_) => NewConversationDialog(
        client: client,
        config: config,
        title: 'Add people',
        groupTitle: null,
        allowGroupName: false,
        confirmLabel: 'Add',
      ),
    );
    if (result == null || result.recipients.isEmpty || !context.mounted) {
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.recipients.length == 1
              ? 'Inviting ${result.recipients.single.displayName ?? result.recipients.single.userId}…'
              : 'Inviting ${result.recipients.length} people…',
        ),
      ),
    );
    try {
      for (final profile in result.recipients) {
        await room.invite(profile.userId);
      }
      // A room previously marked as a 1-on-1 direct chat no longer fits that
      // once someone else joins it.
      if (room.directChatMatrixID != null) {
        await room.removeFromDirectChat();
      }
    } catch (_) {
      if (context.mounted) {
        _showError(
          context,
          'Some people could not be invited to this conversation.',
        );
      }
    }
  }

  Future<void> _deleteConversation(BuildContext context, Room room) async {
    final name = readableMatrixRoomName(room);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: const Text('Delete conversation?'),
        content: Text(
          'Remove "$name" from this account? Other participants will keep '
          'their copies of the conversation.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Deleting conversation…')),
    );
    try {
      await room.leave();
      await room.forget();
      conversationMuteController.removeRoom(room.id);
      archives.removeRoom(room.id);
      try {
        await searchIndex.removeLocalRoom(room.id);
      } catch (_) {
        // The room is already gone. Any stale local search rows are ignored
        // because their room can no longer be opened.
      }
      if (context.mounted) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          const SnackBar(content: Text('Conversation deleted.')),
        );
      }
    } catch (_) {
      if (context.mounted) {
        messenger.hideCurrentSnackBar();
        _showError(
          context,
          'The conversation could not be deleted. Check your connection and '
          'try again.',
        );
      }
    }
  }

  Future<void> _toggleConversationMute(BuildContext context, Room room) async {
    final muted = conversationMuteController.isMuted(room.id);
    try {
      await conversationMuteController.setMuted(room, !muted);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            muted
                ? 'Conversation notifications turned on.'
                : 'Conversation muted.',
          ),
        ),
      );
    } catch (_) {
      if (context.mounted) {
        _showError(
          context,
          muted
              ? 'The conversation could not be unmuted.'
              : 'The conversation could not be muted.',
        );
      }
    }
  }

  void _showSecurityInfo(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.lock_outline),
        title: const Text('Encrypted conversations only'),
        content: const Text(
          'Patrick Messenger refuses to open unencrypted rooms. Device '
          'verification and an independent audit of encrypted history '
          'recovery must be finished before production use.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showError(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _IncomingSharePrompt extends StatefulWidget {
  final IncomingShareController controller;
  final Client client;
  final Future<void> Function(Room room, SharedData share) onSelected;

  const _IncomingSharePrompt({
    required this.controller,
    required this.client,
    required this.onSelected,
  });

  @override
  State<_IncomingSharePrompt> createState() => _IncomingSharePromptState();
}

class _IncomingSharePromptState extends State<_IncomingSharePrompt> {
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_schedulePrompt);
    _schedulePrompt();
  }

  @override
  void didUpdateWidget(covariant _IncomingSharePrompt oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_schedulePrompt);
      widget.controller.addListener(_schedulePrompt);
    }
    _schedulePrompt();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_schedulePrompt);
    super.dispose();
  }

  void _schedulePrompt() {
    if (_showing || widget.controller.current == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showPrompt();
    });
  }

  Future<void> _showPrompt() async {
    final share = widget.controller.current;
    if (_showing || share == null) return;
    _showing = true;
    final rooms = widget.client.rooms
        .where((room) => room.membership == Membership.join && room.encrypted)
        .toList();
    final roomId = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Share with…'),
        content: SizedBox(
          width: 440,
          child: rooms.isEmpty
              ? const Text(
                  'Create or join an encrypted conversation before sharing.',
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_shareDescription(share)),
                    const SizedBox(height: 12),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: rooms.length,
                        itemBuilder: (context, index) {
                          final room = rooms[index];
                          return ListTile(
                            leading: const Icon(Icons.lock_outline),
                            title: Text(readableMatrixRoomName(room)),
                            onTap: () => Navigator.pop(dialogContext, room.id),
                          );
                        },
                      ),
                    ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (!mounted) return;

    widget.controller.consumeCurrent();
    _showing = false;
    final room = roomId == null ? null : widget.client.getRoomById(roomId);
    if (room != null) await widget.onSelected(room, share);
    _schedulePrompt();
  }

  String _shareDescription(SharedData share) {
    if (share.filePaths.isNotEmpty) {
      if (share.filePaths.length == 1) {
        return 'Choose a conversation for ${path.basename(share.filePaths.first)}.';
      }
      return 'Choose a conversation for ${share.filePaths.length} files.';
    }
    return 'Choose a conversation for the shared text.';
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _RoomTile extends StatelessWidget {
  final Room room;
  final bool muted;
  final VoidCallback onTap;
  final VoidCallback onToggleMute;
  final VoidCallback onAddPerson;
  final VoidCallback onDelete;

  const _RoomTile({
    required this.room,
    required this.muted,
    required this.onTap,
    required this.onToggleMute,
    required this.onAddPerson,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final name = readableMatrixRoomName(room);
    final invited = room.membership == Membership.invite;
    final lastMessage = invited
        ? 'Invitation'
        : room.lastEvent?.body ?? 'No messages yet';
    final colors = Theme.of(context).colorScheme;

    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: CircleAvatar(
          backgroundColor: colors.primaryContainer,
          foregroundColor: colors.onPrimaryContainer,
          child: Text(_initial(name)),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 8),
            if (muted) ...[
              Icon(
                Icons.notifications_off_outlined,
                size: 16,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
            ],
            Icon(
              room.encrypted ? Icons.lock_outline : Icons.lock_open_outlined,
              size: 16,
              color: room.encrypted ? colors.primary : colors.error,
            ),
          ],
        ),
        subtitle: ColorEmojiText(
          lastMessage,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (room.notificationCount > 0) ...[
              Badge(label: Text('${room.notificationCount}')),
              const SizedBox(width: 4),
            ],
            PopupMenuButton<_ConversationAction>(
              tooltip: 'Conversation actions',
              onSelected: (action) {
                switch (action) {
                  case _ConversationAction.toggleMute:
                    onToggleMute();
                  case _ConversationAction.addPerson:
                    onAddPerson();
                  case _ConversationAction.delete:
                    onDelete();
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: _ConversationAction.toggleMute,
                  child: ListTile(
                    leading: Icon(
                      muted
                          ? Icons.notifications_outlined
                          : Icons.notifications_off_outlined,
                    ),
                    title: Text(
                      muted ? 'Unmute conversation' : 'Mute conversation',
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuItem(
                  value: _ConversationAction.addPerson,
                  child: ListTile(
                    leading: Icon(Icons.person_add_outlined),
                    title: Text('Add person'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuItem(
                  value: _ConversationAction.delete,
                  child: ListTile(
                    leading: Icon(Icons.delete_outline),
                    title: Text('Delete conversation'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

class _EmptyRooms extends StatelessWidget {
  final VoidCallback onStart;

  const _EmptyRooms({required this.onStart});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.forum_outlined, size: 58),
              const SizedBox(height: 20),
              Text(
                'No conversations yet',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              const Text(
                'Start a private, non-federated conversation with another '
                'account on your server.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onStart,
                icon: const Icon(Icons.add_comment_outlined),
                label: const Text('Start a conversation'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _AccountAction { settings, signOut }

enum _ConversationAction { toggleMute, addPerson, delete }

String _initial(String name) {
  final trimmed = name.trim();
  return trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase();
}
