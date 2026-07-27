import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import 'emoji_picker_dialog.dart';

enum MessageAction {
  reactMore,
  reply,
  edit,
  copy,
  forward,
  select,
  pin,
  info,
  resend,
  cancelSend,
  delete,
}

sealed class MessageActionResult {
  const MessageActionResult();
}

class SelectedMessageAction extends MessageActionResult {
  final MessageAction action;

  const SelectedMessageAction(this.action);
}

class SelectedReaction extends MessageActionResult {
  final String emoji;

  const SelectedReaction(this.emoji);
}

List<MessageAction> availableMessageActions({
  required bool mine,
  required bool isText,
  required bool canRedact,
  EventStatus status = EventStatus.synced,
}) {
  return [
    MessageAction.reply,
    if (mine && isText) MessageAction.edit,
    if (isText) MessageAction.copy,
    MessageAction.forward,
    MessageAction.select,
    MessageAction.pin,
    MessageAction.info,
    if (mine && status.isError) MessageAction.resend,
    if (mine && !status.isSent) MessageAction.cancelSend,
    if (canRedact) MessageAction.delete,
  ];
}

Future<MessageActionResult?> showMessageActionDialog({
  required BuildContext context,
  required Event event,
  required bool mine,
  required bool isText,
  required bool isPinned,
}) {
  final mobile =
      Theme.of(context).platform == TargetPlatform.android ||
      Theme.of(context).platform == TargetPlatform.iOS;
  if (mobile) {
    return showModalBottomSheet<MessageActionResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: _MessageActionContent(
          event: event,
          mine: mine,
          isText: isText,
          isPinned: isPinned,
        ),
      ),
    );
  }
  return showDialog<MessageActionResult>(
    context: context,
    builder: (dialogContext) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: _MessageActionContent(
          event: event,
          mine: mine,
          isText: isText,
          isPinned: isPinned,
        ),
      ),
    ),
  );
}

class _MessageActionContent extends StatelessWidget {
  final Event event;
  final bool mine;
  final bool isText;
  final bool isPinned;

  const _MessageActionContent({
    required this.event,
    required this.mine,
    required this.isText,
    required this.isPinned,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final actions = availableMessageActions(
      mine: mine,
      isText: isText,
      canRedact: event.canRedact,
      status: event.status,
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final emoji in quickReactionEmojis)
                      IconButton(
                        constraints: const BoxConstraints.tightFor(
                          width: 40,
                          height: 42,
                        ),
                        padding: EdgeInsets.zero,
                        onPressed: () =>
                            Navigator.pop(context, SelectedReaction(emoji)),
                        tooltip: 'React $emoji',
                        icon: Text(emoji, style: const TextStyle(fontSize: 21)),
                      ),
                    IconButton(
                      constraints: const BoxConstraints.tightFor(
                        width: 40,
                        height: 42,
                      ),
                      padding: EdgeInsets.zero,
                      onPressed: () => Navigator.pop(
                        context,
                        const SelectedMessageAction(MessageAction.reactMore),
                      ),
                      tooltip: 'More reactions',
                      icon: const Icon(Icons.add_reaction_outlined),
                    ),
                  ],
                ),
              ),
            ),
          ),
          _ActionTile(
            icon: Icons.reply,
            label: 'Reply',
            action: MessageAction.reply,
          ),
          if (actions.contains(MessageAction.edit))
            const _ActionTile(
              icon: Icons.edit_outlined,
              label: 'Edit',
              action: MessageAction.edit,
            ),
          if (actions.contains(MessageAction.copy))
            const _ActionTile(
              icon: Icons.content_copy_outlined,
              label: 'Copy text',
              action: MessageAction.copy,
            ),
          const _ActionTile(
            icon: Icons.forward_outlined,
            label: 'Forward',
            action: MessageAction.forward,
          ),
          const _ActionTile(
            icon: Icons.check_circle_outline,
            label: 'Select',
            action: MessageAction.select,
          ),
          _ActionTile(
            icon: isPinned ? Icons.push_pin : Icons.push_pin_outlined,
            label: isPinned ? 'Unpin' : 'Pin',
            action: MessageAction.pin,
          ),
          const _ActionTile(
            icon: Icons.info_outline,
            label: 'Info',
            action: MessageAction.info,
          ),
          if (actions.contains(MessageAction.resend))
            const _ActionTile(
              icon: Icons.refresh,
              label: 'Resend',
              action: MessageAction.resend,
            ),
          if (actions.contains(MessageAction.cancelSend))
            const _ActionTile(
              icon: Icons.cancel_outlined,
              label: 'Cancel sending',
              action: MessageAction.cancelSend,
              destructive: true,
            ),
          if (actions.contains(MessageAction.delete))
            const _ActionTile(
              icon: Icons.delete_outline,
              label: 'Delete for everyone',
              action: MessageAction.delete,
              destructive: true,
            ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final MessageAction action;
  final bool destructive;

  const _ActionTile({
    required this.icon,
    required this.label,
    required this.action,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = destructive ? Theme.of(context).colorScheme.error : null;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label, style: TextStyle(color: color)),
      onTap: () => Navigator.pop(context, SelectedMessageAction(action)),
    );
  }
}
