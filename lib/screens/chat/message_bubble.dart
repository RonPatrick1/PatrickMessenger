import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart' as sharing;

import '../../archive/archive_contract.dart';
import '../../archive/archive_repository.dart';
import '../../matrix/display_names.dart';
import '../../receipts/message_receipt_service.dart';
import 'emoji_style.dart';
import 'liam_icon.dart';
import 'message_interactions.dart';
import 'message_status_indicator.dart';

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
  final MessageReceiptService receiptService;
  final ArchiveRoomData archive;

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
    required this.receiptService,
    required this.archive,
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
                              archive: archive,
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
                                  ListenableBuilder(
                                    listenable: receiptService,
                                    builder: (context, _) =>
                                        MessageStatusIndicator(
                                          summary: receiptService.summary(
                                            event,
                                          ),
                                          color: textColor.withValues(
                                            alpha: 0.75,
                                          ),
                                        ),
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
  final ArchiveRoomData archive;

  const _ReplyPreview({
    required this.event,
    required this.timeline,
    required this.textColor,
    required this.archive,
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
    final archiveId = widget.event.content[archiveReplyKey]?.toString();
    if (widget.event.inReplyToEventId() == null && archiveId == null) {
      return const SizedBox.shrink();
    }
    if (archiveId != null) {
      final message = widget.archive.message(archiveId);
      if (message == null) return const SizedBox.shrink();
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(9, 7, 9, 7),
        decoration: BoxDecoration(
          color: widget.textColor.withValues(alpha: 0.08),
          border: Border(left: BorderSide(color: widget.textColor, width: 3)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: ColorEmojiText(
          '${message.authorName}: ${message.body}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      );
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
              ColorEmojiText(
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
              label: ReactionLabel(emoji: group.emoji, count: group.count),
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
      MessageTypes.File || MessageTypes.Video || MessageTypes.Audio =>
        _EncryptedAttachment(event: event, textColor: textColor),
      _ =>
        isLiamAnswer(event, liamUserId: liamUserId)
            ? _LiamAnswerContent(event: event, textColor: textColor)
            : ColorEmojiText(
                visibleMessageBody(event),
                selectable: true,
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

class _EncryptedAttachment extends StatefulWidget {
  final Event event;
  final Color textColor;

  const _EncryptedAttachment({required this.event, required this.textColor});

  @override
  State<_EncryptedAttachment> createState() => _EncryptedAttachmentState();
}

class _EncryptedAttachmentState extends State<_EncryptedAttachment> {
  bool _opening = false;

  @override
  Widget build(BuildContext context) {
    final icon = switch (widget.event.messageType) {
      MessageTypes.Video => Icons.video_file_outlined,
      MessageTypes.Audio => Icons.audio_file_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: _opening ? null : _openAttachment,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _opening
                ? const SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(icon, color: widget.textColor),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ColorEmojiText(
                    widget.event.body,
                    style: TextStyle(color: widget.textColor),
                  ),
                  Text(
                    _desktop ? 'Tap to save' : 'Tap to open or save',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: widget.textColor.withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openAttachment() async {
    setState(() => _opening = true);
    try {
      if (_desktop) {
        final destination = await getSaveLocation(
          suggestedName: path.basename(widget.event.body),
        );
        if (destination == null) return;
        final downloaded = await widget.event.downloadAndDecryptAttachment();
        await File(
          destination.path,
        ).writeAsBytes(downloaded.bytes, flush: true);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Saved to ${destination.path}')),
          );
        }
        return;
      }

      final downloaded = await widget.event.downloadAndDecryptAttachment();
      final directory = await getTemporaryDirectory();
      final safeName = path
          .basename(downloaded.name)
          .replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_');
      final output = File(
        path.join(directory.path, '${widget.event.eventId.hashCode}_$safeName'),
      );
      await output.writeAsBytes(downloaded.bytes, flush: true);
      if (!mounted) return;
      final renderBox = context.findRenderObject() as RenderBox?;
      await sharing.SharePlus.instance.share(
        sharing.ShareParams(
          title: downloaded.name,
          files: [
            sharing.XFile(
              output.path,
              name: downloaded.name,
              mimeType: downloaded.mimeType,
            ),
          ],
          fileNameOverrides: [downloaded.name],
          sharePositionOrigin: renderBox == null
              ? null
              : renderBox.localToGlobal(Offset.zero) & renderBox.size,
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('The attachment could not be opened.')),
        );
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  bool get _desktop =>
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows;
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
        ColorEmojiText(
          visibleLiamAnswer(event),
          selectable: true,
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
