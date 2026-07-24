import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../config/app_config.dart';
import '../matrix/display_names.dart';
import '../matrix/room_rename_permissions.dart';
import '../notifications/liam_chatter_visibility.dart';
import '../notifications/message_notification_service.dart';
import '../notifications/notification_preferences.dart';
import '../settings/text_scale_preference.dart';
import '../settings/theme_preference.dart';
import 'chat_screen.dart';
import 'history_recovery_dialog.dart';
import 'profile_dialog.dart';

class RoomsScreen extends StatelessWidget {
  final Client client;
  final AppConfig config;
  final ThemePreferenceController themeController;
  final TextScalePreferenceController textScaleController;
  final NotificationPreferenceController notificationController;
  final MessageNotificationService notificationService;
  final LiamChatterVisibilityController liamChatterVisibility;

  const RoomsScreen({
    required this.client,
    required this.config,
    required this.themeController,
    required this.textScaleController,
    required this.notificationController,
    required this.notificationService,
    required this.liamChatterVisibility,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    RoomRenamePermissionUpgrader.schedule(client);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Messages'),
        actions: [
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
      body: Column(
        children: [
          HistoryRecoveryBanner(client: client),
          Expanded(
            child: StreamBuilder<SyncUpdate>(
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
                      onTap: () => _openRoom(context, room),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openRoom(BuildContext context, Room room) async {
    if (room.membership == Membership.invite) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Accept invitation?'),
          content: Text(
            'Join ${room.getLocalizedDisplayname()} on your private server?',
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
          giphyApiKey: config.giphyApiKey,
          liamUserId: config.liamUserId,
          textScaleController: textScaleController,
          liamChatterVisibility: liamChatterVisibility,
        ),
      ),
    );
  }

  Future<void> _startConversation(BuildContext context) async {
    final username = await showDialog<String>(
      context: context,
      builder: (_) => _NewConversationDialog(config: config),
    );
    if (username == null || username.isEmpty || !context.mounted) return;

    final matrixId = config.matrixIdFor(username);
    if (!matrixId.endsWith(':${config.serverName}')) {
      _showError(
        context,
        'Only people on ${config.serverName} can be messaged.',
      );
      return;
    }
    if (matrixId == client.userID) {
      _showError(context, 'Choose another account.');
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
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

class _RoomTile extends StatelessWidget {
  final Room room;
  final VoidCallback onTap;

  const _RoomTile({required this.room, required this.onTap});

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
            Icon(
              room.encrypted ? Icons.lock_outline : Icons.lock_open_outlined,
              size: 16,
              color: room.encrypted ? colors.primary : colors.error,
            ),
          ],
        ),
        subtitle: Text(
          lastMessage,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: room.notificationCount > 0
            ? Badge(label: Text('${room.notificationCount}'))
            : const Icon(Icons.chevron_right),
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

class _NewConversationDialog extends StatefulWidget {
  final AppConfig config;

  const _NewConversationDialog({required this.config});

  @override
  State<_NewConversationDialog> createState() => _NewConversationDialogState();
}

class _NewConversationDialogState extends State<_NewConversationDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New encrypted conversation'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        autocorrect: false,
        onSubmitted: (value) => _finish(value),
        decoration: InputDecoration(
          labelText: 'Username',
          helperText: 'Account on ${widget.config.serverName}',
          helperMaxLines: 2,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => _finish(_controller.text),
          child: const Text('Create'),
        ),
      ],
    );
  }

  void _finish(String value) {
    Navigator.pop(context, value.trim());
  }
}

enum _AccountAction { settings, signOut }

String _initial(String name) {
  final trimmed = name.trim();
  return trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase();
}
