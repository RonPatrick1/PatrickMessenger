import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../archive/archive_models.dart';
import '../../archive/archive_repository.dart';
import 'emoji_style.dart';
import 'image_gallery_layout.dart';
import 'swipeable_image_gallery.dart';
import 'message_status_indicator.dart';

class ArchiveMessageBubble extends StatelessWidget {
  final ArchiveMessage message;
  final ArchiveRoomData archive;
  final bool mine;
  final VoidCallback onOpenActions;
  final ValueChanged<String> onReaction;

  const ArchiveMessageBubble({
    required this.message,
    required this.archive,
    required this.mine,
    required this.onOpenActions,
    required this.onReaction,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final bubbleColor = mine
        ? colors.primaryContainer
        : colors.surfaceContainerHigh;
    final textColor = mine
        ? colors.onPrimaryContainer
        : colors.onSurfaceVariant;
    return Align(
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
          child: Column(
            crossAxisAlignment: mine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onLongPress: onOpenActions,
                onSecondaryTap: onOpenActions,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: bubbleColor,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(18),
                      topRight: const Radius.circular(18),
                      bottomLeft: Radius.circular(mine ? 18 : 5),
                      bottomRight: Radius.circular(mine ? 5 : 18),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!mine)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 5),
                            child: Text(
                              message.authorName,
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(
                                    color: colors.primary,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                          ),
                        if (message.replyToId != null)
                          _ArchiveReplyPreview(
                            message: archive.message(message.replyToId!),
                            color: textColor,
                          ),
                        if (message.deleted)
                          Text(
                            'Message deleted',
                            style: TextStyle(
                              color: textColor.withValues(alpha: 0.72),
                              fontStyle: FontStyle.italic,
                            ),
                          )
                        else ...[
                          _ArchiveAttachmentCollection(
                            archive: archive,
                            attachments: message.attachments,
                            color: textColor,
                          ),
                          if (message.body.isNotEmpty)
                            ColorEmojiText(
                              message.body,
                              selectable: true,
                              style: TextStyle(color: textColor),
                            ),
                        ],
                        const SizedBox(height: 4),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (message.edited) ...[
                              Text(
                                'edited',
                                style: TextStyle(
                                  color: textColor.withValues(alpha: 0.7),
                                  fontSize: 11,
                                ),
                              ),
                              const SizedBox(width: 6),
                            ],
                            Text(
                              TimeOfDay.fromDateTime(
                                message.timestamp,
                              ).format(context),
                              style: TextStyle(
                                color: textColor.withValues(alpha: 0.7),
                                fontSize: 11,
                              ),
                            ),
                            if (mine) ...[
                              const SizedBox(width: 4),
                              MessageStatusIndicator.imported(
                                state: message.deliveryState,
                                color: textColor.withValues(alpha: 0.75),
                              ),
                            ],
                            IconButton(
                              onPressed: onOpenActions,
                              tooltip: 'Message actions',
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
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              _ArchiveReactionBar(
                message: message,
                ownUserId: archive.room.client.userID,
                onReaction: onReaction,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArchiveReplyPreview extends StatelessWidget {
  final ArchiveMessage? message;
  final Color color;

  const _ArchiveReplyPreview({required this.message, required this.color});

  @override
  Widget build(BuildContext context) {
    final value = message;
    if (value == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: ColorEmojiText(
        '${value.authorName}: ${value.body}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _ArchiveAttachmentCollection extends StatelessWidget {
  final ArchiveRoomData archive;
  final List<ArchiveAttachment> attachments;
  final Color color;

  const _ArchiveAttachmentCollection({
    required this.archive,
    required this.attachments,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final galleryImages = attachments
        .where((attachment) => attachment.isImage && !attachment.missing)
        .toList(growable: false);

    final children = <Widget>[];
    var galleryAdded = false;

    for (final attachment in attachments) {
      Widget child;

      if (galleryImages.length > 1 &&
          attachment.isImage &&
          !attachment.missing) {
        if (galleryAdded) continue;

        galleryAdded = true;
        child = _ArchiveImageGallery(
          archive: archive,
          attachments: galleryImages,
          color: color,
        );
      } else {
        child = _ArchiveAttachmentView(
          archive: archive,
          attachment: attachment,
          color: color,
        );
      }

      children.add(
        Padding(padding: const EdgeInsets.only(bottom: 8), child: child),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

class _ArchiveImageGallery extends StatelessWidget {
  final ArchiveRoomData archive;
  final List<ArchiveAttachment> attachments;
  final Color color;

  const _ArchiveImageGallery({
    required this.archive,
    required this.attachments,
    required this.color,
  });

  List<SwipeableGalleryImageLoader> get _imageLoaders => attachments
      .map<SwipeableGalleryImageLoader>(
        (attachment) =>
            () async => SwipeableGalleryImage(
              bytes: await archive.loadAttachment(attachment),
              name: attachment.name,
              mimeType: attachment.mimeType,
            ),
      )
      .toList(growable: false);

  Future<void> _showImages(BuildContext context, int initialIndex) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.9),
      builder: (_) => SwipeableImageGallery(
        imageLoaders: _imageLoaders,
        initialIndex: initialIndex,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final captionedAttachments = attachments
        .where((attachment) => (attachment.caption ?? '').trim().isNotEmpty)
        .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ImageGalleryLayout(
          itemCount: attachments.length,
          onItemTap: (index) => _showImages(context, index),
          itemBuilder: (context, index) => _ArchiveGalleryImageTile(
            archive: archive,
            attachment: attachments[index],
          ),
        ),
        for (final attachment in captionedAttachments) ...[
          const SizedBox(height: 6),
          ColorEmojiText(
            attachment.caption!,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color),
          ),
        ],
      ],
    );
  }
}

class _ArchiveGalleryImageTile extends StatelessWidget {
  final ArchiveRoomData archive;
  final ArchiveAttachment attachment;

  const _ArchiveGalleryImageTile({
    required this.archive,
    required this.attachment,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: archive.loadAttachment(attachment),
      builder: (context, snapshot) {
        final bytes = snapshot.data;

        if (bytes != null) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox.expand(
              child: Image.memory(
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
            ),
          );
        }

        if (snapshot.hasError) {
          return const SizedBox.expand(
            child: Center(
              child: Text('Picture unavailable', textAlign: TextAlign.center),
            ),
          );
        }

        return const SizedBox.expand(
          child: Center(child: CircularProgressIndicator()),
        );
      },
    );
  }
}

class _ArchiveAttachmentView extends StatelessWidget {
  final ArchiveRoomData archive;
  final ArchiveAttachment attachment;
  final Color color;

  const _ArchiveAttachmentView({
    required this.archive,
    required this.attachment,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    if (attachment.missing) {
      return Text('Missing media: ${attachment.name}');
    }
    if (!attachment.isImage) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_drive_file_outlined),
          const SizedBox(width: 8),
          Flexible(
            child: ColorEmojiText(
              attachment.name,
              style: TextStyle(color: color),
            ),
          ),
        ],
      );
    }
    return FutureBuilder<Uint8List>(
      future: archive.loadAttachment(attachment),
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: () => showDialog<void>(
                  context: context,
                  barrierColor: Colors.black.withValues(alpha: 0.9),
                  builder: (_) => Dialog.fullscreen(
                    backgroundColor: Colors.black,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: InteractiveViewer(
                            maxScale: 5,
                            child: Center(child: Image.memory(snapshot.data!)),
                          ),
                        ),
                        SafeArea(
                          child: IconButton.filledTonal(
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.close),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.memory(
                    snapshot.data!,
                    width: 280,
                    height: 210,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  ),
                ),
              ),
              if ((attachment.caption ?? '').isNotEmpty) ...[
                const SizedBox(height: 6),
                ColorEmojiText(
                  attachment.caption!,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: color),
                ),
              ],
            ],
          );
        }
        if (snapshot.hasError) return const Text('Picture unavailable');
        return const SizedBox(
          width: 220,
          height: 110,
          child: Center(child: CircularProgressIndicator()),
        );
      },
    );
  }
}

class _ArchiveReactionBar extends StatelessWidget {
  final ArchiveMessage message;
  final String? ownUserId;
  final ValueChanged<String> onReaction;

  const _ArchiveReactionBar({
    required this.message,
    required this.ownUserId,
    required this.onReaction,
  });

  @override
  Widget build(BuildContext context) {
    final grouped = <String, List<ArchiveReaction>>{};
    for (final reaction in message.reactions) {
      (grouped[reaction.emoji] ??= []).add(reaction);
    }
    if (grouped.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 4,
      children: grouped.entries.map((entry) {
        final mine = entry.value.any(
          (item) => item.authorMatrixId == ownUserId,
        );
        return ActionChip(
          label: ReactionLabel(emoji: entry.key, count: entry.value.length),
          side: BorderSide(
            color: mine
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outlineVariant,
          ),
          onPressed: () => onReaction(entry.key),
        );
      }).toList(),
    );
  }
}
