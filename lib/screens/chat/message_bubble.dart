import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../matrix/display_names.dart';
import 'liam_icon.dart';
import 'message_interactions.dart';

class MessageBubble extends StatelessWidget {
  final Event event;
  final Timeline timeline;
  final bool mine;
  final bool selectionMode;
  final bool selected;
  final bool pinned;
  final bool actionsEnabled;
  final String liamUserId;
  final VoidCallback onOpenActions;
  final VoidCallback onSelectionTap;
  final ValueChanged<String> onReaction;

  const MessageBubble({
    required this.event,
    required this.timeline,
    required this.mine,
    required this.selectionMode,
    required this.selected,
    required this.pinned,
    required this.actionsEnabled,
    required this.liamUserId,
    required this.onOpenActions,
    required this.onSelectionTap,
    required this.onReaction,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final displayEvent = event.getDisplayEvent(timeline);
    final liamAnswer = isLiamAnswer(displayEvent, liamUserId: liamUserId);
    final colors = Theme.of(context).colorScheme;
    final time = TimeOfDay.fromDateTime(event.originServerTs).format(context);
    final bubbleColor = selected
        ? colors.tertiaryContainer
        : mine
        ? colors.primaryContainer
        : colors.surfaceContainerHigh;
    final textColor = selected
        ? colors.onTertiaryContainer
        : mine
        ? colors.onPrimaryContainer
        : colors.onSurfaceVariant;
    final edited = event.hasAggregatedEvents(timeline, RelationshipTypes.edit);

    return Material(
      color: selected
          ? colors.tertiaryContainer.withValues(alpha: 0.22)
          : Colors.transparent,
      child: InkWell(
        onTap: selectionMode && actionsEnabled ? onSelectionTap : null,
        onLongPress: actionsEnabled ? onOpenActions : null,
        onSecondaryTap: actionsEnabled ? onOpenActions : null,
        child: Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: EdgeInsets.only(
                top: 4,
                bottom: 4,
                left: mine ? 52 : 0,
                right: mine ? 0 : 52,
              ),
              child: Opacity(
                opacity: event.status.isSent ? 1 : 0.58,
                child: Column(
                  crossAxisAlignment: mine
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: bubbleColor,
                        borderRadius: BorderRadius.only(
                          topLeft: const Radius.circular(18),
                          topRight: const Radius.circular(18),
                          bottomLeft: Radius.circular(mine ? 18 : 5),
                          bottomRight: Radius.circular(mine ? 5 : 18),
                        ),
                        border: selected
                            ? Border.all(color: colors.tertiary, width: 2)
                            : null,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (!mine && !liamAnswer)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 5),
                                child: Text(
                                  readableMatrixUserName(
                                    event.senderFromMemoryOrFallback,
                                  ),
                                  style: Theme.of(context).textTheme.labelMedium
                                      ?.copyWith(
                                        color: colors.primary,
                                        fontWeight: FontWeight.w700,
                                      ),
                                ),
                              ),
                            _ReplyPreview(
                              event: event,
                              timeline: timeline,
                              textColor: textColor,
                            ),
                            _MessageContent(
                              event: displayEvent,
                              textColor: textColor,
                              liamUserId: liamUserId,
                            ),
                            const SizedBox(height: 4),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (pinned) ...[
                                  Icon(
                                    Icons.push_pin,
                                    size: 13,
                                    color: textColor.withValues(alpha: 0.7),
                                  ),
                                  const SizedBox(width: 4),
                                ],
                                if (edited) ...[
                                  Text(
                                    'edited',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: textColor.withValues(
                                            alpha: 0.7,
                                          ),
                                        ),
                                  ),
                                  const SizedBox(width: 6),
                                ],
                                Text(
                                  time,
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: textColor.withValues(alpha: 0.7),
                                      ),
                                ),
                                if (mine) ...[
                                  const SizedBox(width: 4),
                                  Icon(
                                    event.receipts.any(
                                          (receipt) =>
                                              receipt.user.id !=
                                              event.room.client.userID,
                                        )
                                        ? Icons.done_all
                                        : Icons.done,
                                    size: 15,
                                    color: textColor.withValues(alpha: 0.75),
                                  ),
                                ],
                                if (!selectionMode && actionsEnabled) ...[
                                  const SizedBox(width: 2),
                                  IconButton(
                                    onPressed: onOpenActions,
                                    tooltip:
                                        'Message actions: reply, edit, '
                                        'delete, and more',
                                    visualDensity: VisualDensity.compact,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints.tightFor(
                                      width: 30,
                                      height: 26,
                                    ),
                                    icon: Icon(
                                      Icons.more_horiz,
                                      size: 19,
                                      color: textColor.withValues(alpha: 0.8),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    _ReactionBar(
                      event: event,
                      timeline: timeline,
                      onReaction: onReaction,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReplyPreview extends StatefulWidget {
  final Event event;
  final Timeline timeline;
  final Color textColor;

  const _ReplyPreview({
    required this.event,
    required this.timeline,
    required this.textColor,
  });

  @override
  State<_ReplyPreview> createState() => _ReplyPreviewState();
}

class _ReplyPreviewState extends State<_ReplyPreview> {
  late final Future<Event?> _reply = widget.event.getReplyEvent(
    widget.timeline,
  );

  @override
  Widget build(BuildContext context) {
    if (widget.event.inReplyToEventId() == null) {
      return const SizedBox.shrink();
    }
    return FutureBuilder<Event?>(
      future: _reply,
      builder: (context, snapshot) {
        final reply = snapshot.data;
        if (reply == null) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.fromLTRB(9, 7, 9, 7),
          decoration: BoxDecoration(
            color: widget.textColor.withValues(alpha: 0.08),
            border: Border(left: BorderSide(color: widget.textColor, width: 3)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                readableMatrixUserName(reply.senderFromMemoryOrFallback),
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: widget.textColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                visibleMessageBody(reply),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: widget.textColor.withValues(alpha: 0.82),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ReactionBar extends StatelessWidget {
  final Event event;
  final Timeline timeline;
  final ValueChanged<String> onReaction;

  const _ReactionBar({
    required this.event,
    required this.timeline,
    required this.onReaction,
  });

  @override
  Widget build(BuildContext context) {
    final groups = groupedReactions(event, timeline, event.room.client.userID);
    if (groups.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final group in groups)
            ActionChip(
              visualDensity: VisualDensity.compact,
              side: BorderSide(
                color: group.reactedByMe
                    ? colors.primary
                    : colors.outlineVariant,
              ),
              backgroundColor: group.reactedByMe
                  ? colors.primaryContainer
                  : colors.surfaceContainer,
              label: Text('${group.emoji} ${group.count}'),
              onPressed: () => onReaction(group.emoji),
            ),
        ],
      ),
    );
  }
}

class _MessageContent extends StatelessWidget {
  final Event event;
  final Color textColor;
  final String liamUserId;

  const _MessageContent({
    required this.event,
    required this.textColor,
    required this.liamUserId,
  });

  @override
  Widget build(BuildContext context) {
    // Liam's picture replies are still real image/sticker events and must
    // render as such. Only an ordinary text message gets the special
    // "Liam" heading treatment — checking that before the message-type
    // switch would swallow Liam's images into a plain text bubble instead.
    return switch (event.messageType) {
      MessageTypes.Image ||
      MessageTypes.Sticker => _EncryptedImage(event: event),
      MessageTypes.File => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_drive_file_outlined),
          const SizedBox(width: 8),
          Flexible(
            child: Text(event.body, style: TextStyle(color: textColor)),
          ),
        ],
      ),
      _ => isLiamAnswer(event, liamUserId: liamUserId)
          ? _LiamAnswerContent(event: event, textColor: textColor)
          : SelectableText(
              visibleMessageBody(event),
              style: TextStyle(
                color: textColor,
                fontSize: event.onlyEmotes && event.numberEmotes <= 5
                    ? 38
                    : null,
              ),
            ),
    };
  }
}

class _LiamAnswerContent extends StatelessWidget {
  final Event event;
  final Color textColor;

  const _LiamAnswerContent({required this.event, required this.textColor});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const LiamIcon(size: 38),
            const SizedBox(width: 9),
            Text(
              'Liam',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: textColor,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SelectableText(
          visibleLiamAnswer(event),
          style: TextStyle(color: textColor),
        ),
      ],
    );
  }
}

class _EncryptedImage extends StatefulWidget {
  final Event event;

  const _EncryptedImage({required this.event});

  @override
  State<_EncryptedImage> createState() => _EncryptedImageState();
}

class _EncryptedImageState extends State<_EncryptedImage> {
  late final Future<MatrixFile> _thumbnail = _loadThumbnail();

  Future<MatrixFile> _loadThumbnail() async {
    try {
      return await widget.event.downloadAndDecryptAttachment(
        getThumbnail: true,
      );
    } catch (_) {
      return widget.event.downloadAndDecryptAttachment();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<MatrixFile>(
      future: _thumbnail,
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (file != null) {
          return Semantics(
            button: true,
            label: 'Open encrypted picture or GIF',
            child: GestureDetector(
              onTap: () => _showFullImage(context),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(
                  file.bytes,
                  width: 280,
                  height: 210,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
              ),
            ),
          );
        }
        if (snapshot.hasError) {
          return const SizedBox(
            width: 220,
            height: 110,
            child: Center(child: Text('Picture unavailable')),
          );
        }
        return const SizedBox(
          width: 220,
          height: 110,
          child: Center(child: CircularProgressIndicator()),
        );
      },
    );
  }

  Future<void> _showFullImage(BuildContext context) async {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.9),
      builder: (context) => _FullImageDialog(event: widget.event),
    );
  }
}

class _FullImageDialog extends StatefulWidget {
  final Event event;

  const _FullImageDialog({required this.event});

  @override
  State<_FullImageDialog> createState() => _FullImageDialogState();
}

class _FullImageDialogState extends State<_FullImageDialog> {
  late final Future<MatrixFile> _image = widget.event
      .downloadAndDecryptAttachment();

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: Stack(
        children: [
          Positioned.fill(
            child: FutureBuilder<MatrixFile>(
              future: _image,
              builder: (context, snapshot) {
                final file = snapshot.data;
                if (file != null) {
                  return InteractiveViewer(
                    minScale: 0.8,
                    maxScale: 5,
                    child: Center(
                      child: Image.memory(file.bytes, gaplessPlayback: true),
                    ),
                  );
                }
                if (snapshot.hasError) {
                  return const Center(
                    child: Text(
                      'Picture unavailable',
                      style: TextStyle(color: Colors.white),
                    ),
                  );
                }
                return const Center(child: CircularProgressIndicator());
              },
            ),
          ),
          SafeArea(
            child: IconButton.filledTonal(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
              tooltip: 'Close',
            ),
          ),
        ],
      ),
    );
  }
}
