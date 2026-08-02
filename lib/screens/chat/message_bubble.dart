import 'dart:async';
import 'dart:io';

import 'package:chewie/chewie.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart' as sharing;
import 'package:video_player/video_player.dart';
import 'package:window_manager/window_manager.dart';

import '../../archive/archive_contract.dart';
import '../../archive/archive_repository.dart';
import '../../matrix/display_names.dart';
import '../../receipts/message_receipt_service.dart';
import '../../services/offset_aes_ctr.dart';
import '../../services/media_save_service.dart';
import '../../services/streaming_encrypted_video_playback.dart';
import 'emoji_picker_dialog.dart';
import 'emoji_style.dart';
import 'image_gallery_layout.dart';
import 'swipeable_image_gallery.dart';
import 'liam_icon.dart';
import 'message_interactions.dart';
import 'message_status_indicator.dart';

class MessageBubble extends StatefulWidget {
  final Event event;
  final List<Event> galleryEvents;
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
  final VoidCallback onReply;
  final MessageReceiptService receiptService;
  final ArchiveRoomData archive;

  const MessageBubble({
    required this.event,
    this.galleryEvents = const <Event>[],
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
    required this.onReply,
    required this.receiptService,
    required this.archive,
    super.key,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  bool get _hoverCapable =>
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows;

  bool _hovering = false;

  void _setHovering(bool value) {
    if (_hovering == value) return;
    setState(() => _hovering = value);
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final galleryEvents = widget.galleryEvents.isEmpty
        ? <Event>[event]
        : widget.galleryEvents;
    final timeline = widget.timeline;
    final mine = widget.mine;
    final selectionMode = widget.selectionMode;
    final selected = widget.selected;
    final pinned = widget.pinned;
    final actionsEnabled = widget.actionsEnabled;
    final liamUserId = widget.liamUserId;
    final onOpenActions = widget.onOpenActions;
    final onSelectionTap = widget.onSelectionTap;
    final onReaction = widget.onReaction;
    final onReply = widget.onReply;
    final receiptService = widget.receiptService;
    final archive = widget.archive;

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
    final groups = groupedReactions(event, timeline, event.room.client.userID);
    final showToolbar = _hovering && actionsEnabled && !selectionMode;

    final bubble = DecoratedBox(
      decoration: BoxDecoration(
        color: bubbleColor,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(mine ? 18 : 5),
          bottomRight: Radius.circular(mine ? 5 : 18),
        ),
        border: selected ? Border.all(color: colors.tertiary, width: 2) : null,
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
                  readableMatrixUserName(event.senderFromMemoryOrFallback),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
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
              imageEvents: galleryEvents,
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
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: textColor.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  time,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: textColor.withValues(alpha: 0.7),
                  ),
                ),
                if (mine) ...[
                  const SizedBox(width: 4),
                  ListenableBuilder(
                    listenable: receiptService,
                    builder: (context, _) => MessageStatusIndicator(
                      summary: receiptService.summary(event),
                      color: textColor.withValues(alpha: 0.75),
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
    );

    final bubbleWithBadges = Stack(
      clipBehavior: Clip.none,
      children: [
        bubble,
        if (groups.isNotEmpty)
          Positioned(
            bottom: -11,
            left: mine ? 6 : null,
            right: mine ? null : 6,
            child: _ReactionBadges(groups: groups, onReaction: onReaction),
          ),
      ],
    );

    // Desktop permanently reserves the quick-action toolbar's exact width.
    // Hovering therefore changes only opacity/content, never the width that
    // the message bubble is allowed to use (and never its wrapping/shape).
    const toolbarWidth = 268.0;
    final reserveToolbar = _hoverCapable && actionsEnabled && !selectionMode;
    final gutter = reserveToolbar ? 4.0 : 52.0;

    // The toolbar is a normal Row sibling directly adjacent to the bubble's
    // own (naturally-sized, Flexible) width — not an absolutely-positioned
    // overlay. An earlier version placed it via Positioned + Clip.none
    // overflowing a narrow Stack, which painted it in the right spot but
    // left it outside Flutter's hit-testable bounds (RenderBox hit-testing
    // only considers a box's own layout size before testing overflowing
    // children), so the mouse left the real hoverable area before ever
    // reaching it and it could never be clicked. A second attempt anchored
    // it via Alignment inside a full-width Stack, which fixed clickability
    // but pinned it to the far edge of the whole row instead of next to the
    // bubble. A Row with the toolbar and the Flexible bubble as siblings
    // sidesteps both problems: it sits directly beside the bubble's actual
    // rendered edge (matching Signal), and it's real, non-overflowing
    // layout, so it's always within bounds.
    final toolbarSlot = reserveToolbar
        ? SizedBox(
            width: toolbarWidth,
            child: showToolbar
                ? Align(
                    alignment: mine
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: _HoverQuickActions(
                        onReaction: onReaction,
                        onReply: onReply,
                        onOpenActions: onOpenActions,
                      ),
                    ),
                  )
                : null,
          )
        : null;

    final content = Material(
      color: selected
          ? colors.tertiaryContainer.withValues(alpha: 0.22)
          : Colors.transparent,
      child: InkWell(
        onTap: selectionMode && actionsEnabled ? onSelectionTap : null,
        onLongPress: actionsEnabled ? onOpenActions : null,
        onSecondaryTap: actionsEnabled ? onOpenActions : null,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final availableBubbleWidth =
                constraints.maxWidth - (reserveToolbar ? toolbarWidth : 0);
            final maximumBubbleWidth = availableBubbleWidth.clamp(1.0, 480.0);
            final bubbleColumn = ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maximumBubbleWidth),
              child: Padding(
                padding: EdgeInsets.only(
                  top: 4,
                  bottom: 4,
                  left: mine ? gutter : 0,
                  right: mine ? 0 : gutter,
                ),
                child: Opacity(
                  opacity: event.status.isSent ? 1 : 0.58,
                  child: Column(
                    crossAxisAlignment: mine
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    children: [
                      bubbleWithBadges,
                      if (groups.isNotEmpty) const SizedBox(height: 15),
                    ],
                  ),
                ),
              ),
            );

            return Align(
              alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (mine && toolbarSlot != null) toolbarSlot,
                  bubbleColumn,
                  if (!mine && toolbarSlot != null) toolbarSlot,
                ],
              ),
            );
          },
        ),
      ),
    );

    if (!_hoverCapable) return content;
    return MouseRegion(
      onEnter: (_) => _setHovering(true),
      onExit: (_) => _setHovering(false),
      child: content,
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

class _ReactionBadges extends StatelessWidget {
  static const _circleSize = 22.0;
  static const _overlapStep = 14.0;

  final List<ReactionGroup> groups;
  final ValueChanged<String> onReaction;

  const _ReactionBadges({required this.groups, required this.onReaction});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    // A single reaction type still reads better as a plain emoji + count
    // pill — there's nothing to overlap yet.
    if (groups.length == 1) {
      final group = groups.single;
      return _badgePill(
        colors: colors,
        reactedByMe: group.reactedByMe,
        onTap: () => onReaction(group.emoji),
        child: ReactionLabel(emoji: group.emoji, count: group.count),
      );
    }

    // Multiple reaction types: a Facebook-style cluster of overlapping
    // circles (one per emoji, most recent on top) followed by the combined
    // total. Each circle sits at a real, non-overflowing Positioned offset
    // within a Stack whose own width is sized to fit them all, so — unlike
    // an earlier attempt at overlap via Positioned + Clip.none overflow —
    // every circle stays genuinely within hit-testable bounds and remains
    // individually tappable.
    final totalCount = groups.fold<int>(0, (sum, group) => sum + group.count);
    final clusterWidth = _circleSize + (groups.length - 1) * _overlapStep;

    return Builder(
      builder: (context) => _badgePill(
        colors: colors,
        reactedByMe: groups.any((group) => group.reactedByMe),
        // Individual circles remain directly tappable wherever they're
        // actually visible (below); this handles taps that land on the
        // pill itself — the total count, or gaps between circles — by
        // "exploding" the whole cluster into a popup where every reaction
        // is fully visible and clickable, including ones mostly hidden
        // behind later circles.
        onTap: () => _showExplodedPopup(context, colors),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: clusterWidth,
              height: _circleSize,
              child: Stack(
                children: [
                  for (final (index, group) in groups.indexed)
                    Positioned(
                      left: index * _overlapStep,
                      width: _circleSize,
                      height: _circleSize,
                      child: Material(
                        shape: CircleBorder(
                          side: BorderSide(color: colors.surface, width: 1.5),
                        ),
                        color: group.reactedByMe
                            ? colors.primaryContainer
                            : colors.surfaceContainerHigh,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => onReaction(group.emoji),
                          child: Center(
                            child: EmojiGlyph(group.emoji, size: 13),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            Text('$totalCount'),
          ],
        ),
      ),
    );
  }

  Future<void> _showExplodedPopup(
    BuildContext context,
    ColorScheme colors,
  ) async {
    final button = context.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );

    final selected = await showMenu<String>(
      context: context,
      position: position,
      color: Colors.transparent,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      items: [
        PopupMenuItem<String>(
          enabled: false,
          padding: EdgeInsets.zero,
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final group in groups)
                _badgePill(
                  colors: colors,
                  reactedByMe: group.reactedByMe,
                  onTap: () => Navigator.of(context).pop(group.emoji),
                  child: ReactionLabel(emoji: group.emoji, count: group.count),
                ),
            ],
          ),
        ),
      ],
    );
    if (selected != null) onReaction(selected);
  }

  Widget _badgePill({
    required ColorScheme colors,
    required bool reactedByMe,
    required VoidCallback? onTap,
    required Widget child,
  }) {
    return Material(
      color: reactedByMe
          ? colors.primaryContainer
          : colors.surfaceContainerHigh,
      shape: StadiumBorder(side: BorderSide(color: colors.surface, width: 1.5)),
      elevation: 1,
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: child,
        ),
      ),
    );
  }
}

class _HoverQuickActions extends StatelessWidget {
  final ValueChanged<String> onReaction;
  final VoidCallback onReply;
  final VoidCallback onOpenActions;

  const _HoverQuickActions({
    required this.onReaction,
    required this.onReply,
    required this.onOpenActions,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final emoji in quickReactionEmojis)
              IconButton(
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                padding: EdgeInsets.zero,
                onPressed: () => onReaction(emoji),
                tooltip: 'React $emoji',
                icon: EmojiGlyph(emoji, size: 17),
              ),
            IconButton(
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              padding: EdgeInsets.zero,
              onPressed: onReply,
              tooltip: 'Reply',
              icon: const Icon(Icons.reply, size: 18),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              padding: EdgeInsets.zero,
              onPressed: onOpenActions,
              tooltip: 'More actions',
              icon: const Icon(Icons.more_horiz, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageContent extends StatelessWidget {
  final Event event;
  final List<Event> imageEvents;
  final Color textColor;
  final String liamUserId;

  const _MessageContent({
    required this.event,
    this.imageEvents = const <Event>[],
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
      MessageTypes.Image || MessageTypes.Sticker =>
        imageEvents.length > 1
            ? _EncryptedImageGallery(events: imageEvents)
            : _EncryptedImage(event: event),
      MessageTypes.Video => _EncryptedVideo(event: event),
      MessageTypes.File || MessageTypes.Audio => _EncryptedAttachment(
        event: event,
        textColor: textColor,
      ),
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

class _EncryptedImageGallery extends StatelessWidget {
  final List<Event> events;

  const _EncryptedImageGallery({required this.events});

  List<SwipeableGalleryImageLoader> get _imageLoaders => events
      .map<SwipeableGalleryImageLoader>(
        (event) => () async {
          final file = await event.downloadAndDecryptAttachment();

          return SwipeableGalleryImage(
            bytes: file.bytes,
            name: file.name,
            mimeType: file.mimeType,
          );
        },
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
    return ImageGalleryLayout(
      itemCount: events.length,
      onItemTap: (index) => _showImages(context, index),
      itemBuilder: (context, index) => _EncryptedImage(
        event: events[index],
        compact: true,
        interactive: false,
      ),
    );
  }
}

class _EncryptedImage extends StatefulWidget {
  final Event event;
  final bool compact;
  final bool interactive;

  const _EncryptedImage({
    required this.event,
    this.compact = false,
    this.interactive = true,
  });

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

  Widget _placeholder(Widget child) {
    if (widget.compact) {
      return SizedBox.expand(child: Center(child: child));
    }

    return SizedBox(width: 220, height: 110, child: Center(child: child));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<MatrixFile>(
      future: _thumbnail,
      builder: (context, snapshot) {
        final file = snapshot.data;

        if (file != null) {
          final image = ClipRRect(
            borderRadius: BorderRadius.circular(widget.compact ? 8 : 12),
            child: widget.compact
                ? SizedBox.expand(
                    child: Image.memory(
                      file.bytes,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    ),
                  )
                : Image.memory(
                    file.bytes,
                    width: 280,
                    height: 210,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  ),
          );

          if (!widget.interactive) return image;

          return Semantics(
            button: true,
            label: 'Open encrypted picture or GIF',
            child: GestureDetector(
              onTap: () => _showFullImage(context),
              child: image,
            ),
          );
        }

        if (snapshot.hasError) {
          return _placeholder(
            const Text('Picture unavailable', textAlign: TextAlign.center),
          );
        }

        return _placeholder(const CircularProgressIndicator());
      },
    );
  }

  Future<void> _showFullImage(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.9),
      builder: (_) => SwipeableImageGallery(
        imageLoaders: [
          () async {
            final file = await widget.event.downloadAndDecryptAttachment();

            return SwipeableGalleryImage(
              bytes: file.bytes,
              name: file.name,
              mimeType: file.mimeType,
            );
          },
        ],
      ),
    );
  }
}

class _EncryptedVideo extends StatefulWidget {
  final Event event;

  const _EncryptedVideo({required this.event});

  @override
  State<_EncryptedVideo> createState() => _EncryptedVideoState();
}

class _EncryptedVideoState extends State<_EncryptedVideo> {
  // Synapse (and homeservers generally) can only generate thumbnails for
  // image content, never for video. `downloadAndDecryptAttachment` silently
  // downgrades `getThumbnail: true` to the full attachment when the event
  // has no separate `info.thumbnail_url`/`thumbnail_file` — which is every
  // video this app sends, since none of the send paths attach one. Without
  // this `hasThumbnail` gate, that fallback would hand the raw video bytes
  // to `Image.memory`, which fails to decode them as an image.
  late final Future<MatrixFile>? _thumbnail = widget.event.hasThumbnail
      ? widget.event.downloadAndDecryptAttachment(getThumbnail: true)
      : null;

  bool _loadingFull = false;
  bool _savingVideo = false;
  bool _videoSaved = false;
  String? _videoSaveStatus;
  Timer? _videoSaveStatusTimer;
  Player? _player;
  VideoController? _controller;
  VideoPlayerController? _linuxVideoController;
  ChewieController? _linuxChewieController;
  bool _linuxNativeFullscreen = false;
  EncryptedVideoStreamSession? _session;
  StreamSubscription<String>? _sessionEvents;

  @override
  void initState() {
    super.initState();

    if (Platform.isLinux) {
      HardwareKeyboard.instance.addHandler(_handleLinuxFullscreenKey);
    }
  }

  bool _handleLinuxFullscreenKey(KeyEvent event) {
    if (!Platform.isLinux ||
        event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return false;
    }

    final controller = _linuxChewieController;
    if (controller == null || !controller.isFullScreen) {
      return false;
    }

    controller.exitFullScreen();
    return true;
  }

  Future<void> _enterAndroidFullscreenPreservingOrientation() async {
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.immersiveSticky,
      overlays: const [],
    );
  }

  Future<void> _exitAndroidFullscreenPreservingOrientation() async {
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
  }

  Future<void> _setLinuxNativeFullscreen(bool fullscreen) async {
    try {
      await windowManager.setFullScreen(fullscreen);
    } catch (error) {
      debugPrint('Could not change Linux fullscreen state: $error');
    }
  }

  void _syncLinuxNativeFullscreen() {
    final controller = _linuxChewieController;
    if (!Platform.isLinux || controller == null) return;

    final fullscreen = controller.isFullScreen;
    if (fullscreen == _linuxNativeFullscreen) return;

    _linuxNativeFullscreen = fullscreen;
    unawaited(_setLinuxNativeFullscreen(fullscreen));
  }

  void _disposeLinuxChewieController() {
    final controller = _linuxChewieController;

    if (controller != null) {
      controller.removeListener(_syncLinuxNativeFullscreen);
      controller.dispose();
    }

    if (Platform.isLinux && _linuxNativeFullscreen) {
      _linuxNativeFullscreen = false;
      unawaited(_setLinuxNativeFullscreen(false));
    }
  }

  @override
  void dispose() {
    if (Platform.isLinux) {
      HardwareKeyboard.instance.removeHandler(_handleLinuxFullscreenKey);
    }

    _videoSaveStatusTimer?.cancel();
    _sessionEvents?.cancel();
    _disposeLinuxChewieController();
    _linuxVideoController?.dispose();
    _session?.dispose();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _startPlayback() async {
    setState(() => _loadingFull = true);
    try {
      final event = widget.event;
      final fileMap = event.content.tryGetMap<String, Object?>('file');
      final mxcUrl = event.attachmentMxcUrl;
      final totalLength = event.infoMap.tryGet<int>('size');
      if (fileMap == null || mxcUrl == null || totalLength == null) {
        throw StateError('This video has no playable attachment.');
      }
      final key = decodeUnpaddedBase64(
        fileMap.tryGetMap<String, Object?>('key')?.tryGet<String>('k') ?? '',
      );
      final iv = decodeUnpaddedBase64(fileMap.tryGet<String>('iv') ?? '');
      final mimeType = event.infoMap.tryGet<String>('mimetype') ?? 'video/mp4';

      final client = event.room.client;
      final accessToken = client.accessToken;
      if (accessToken == null) throw StateError('Not connected.');
      final downloadUri = await mxcUrl.getDownloadUri(client);

      final session = await EncryptedVideoStreamSession.start(
        downloadUri: downloadUri,
        accessToken: accessToken,
        key: key,
        iv: iv,
        totalLength: totalLength,
        mimeType: mimeType,
      );
      final sessionEvents = session.events.listen((message) {
        if (message == 'integrity-failure' && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('This video failed an integrity check.'),
            ),
          );
          _stop();
        }
      });

      final mediaUrl = Uri.parse('http://127.0.0.1:${session.port}/video');

      if (Platform.isLinux) {
        final controller = VideoPlayerController.networkUrl(mediaUrl);
        ChewieController? chewieController;

        try {
          await controller.initialize();
          chewieController = ChewieController(
            videoPlayerController: controller,
            aspectRatio: controller.value.aspectRatio,
            autoPlay: true,
            looping: false,
            showControls: true,
            allowFullScreen: true,
            allowMuting: true,
            customControls: const MaterialControls(),
          );
        } catch (_) {
          chewieController?.dispose();
          await controller.dispose();
          await sessionEvents.cancel();
          session.dispose();
          rethrow;
        }

        if (!mounted) {
          chewieController.dispose();
          await controller.dispose();
          await sessionEvents.cancel();
          session.dispose();
          return;
        }

        chewieController.addListener(_syncLinuxNativeFullscreen);

        setState(() {
          _session = session;
          _sessionEvents = sessionEvents;
          _linuxVideoController = controller;
          _linuxChewieController = chewieController;
          _linuxNativeFullscreen = false;
          _loadingFull = false;
        });
      } else {
        final player = Player();
        final controller = VideoController(player);

        try {
          await player.open(Media(mediaUrl.toString()));
        } catch (_) {
          player.dispose();
          await sessionEvents.cancel();
          session.dispose();
          rethrow;
        }

        if (!mounted) {
          player.dispose();
          await sessionEvents.cancel();
          session.dispose();
          return;
        }

        setState(() {
          _session = session;
          _sessionEvents = sessionEvents;
          _player = player;
          _controller = controller;
          _loadingFull = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loadingFull = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('The video could not be played.')),
        );
      }
    }
  }

  void _stop() {
    _sessionEvents?.cancel();
    _disposeLinuxChewieController();
    _linuxVideoController?.dispose();
    _session?.dispose();
    _player?.dispose();

    setState(() {
      _sessionEvents = null;
      _linuxChewieController = null;
      _linuxVideoController = null;
      _session = null;
      _player = null;
      _controller = null;
    });
  }

  Future<void> _saveVideo() async {
    if (_savingVideo || _videoSaved) return;
    _videoSaveStatusTimer?.cancel();
    setState(() {
      _savingVideo = true;
      _videoSaveStatus = 'Downloading and saving video…';
    });
    try {
      final video = await widget.event.downloadAndDecryptAttachment();
      final result = await MediaSaveService.saveVideo(
        bytes: video.bytes,
        name: video.name,
        mimeType: video.mimeType,
      );
      if (mounted) {
        setState(() {
          _videoSaved = result != null;
          _videoSaveStatus = result?.message ?? 'Save canceled.';
        });
        _dismissVideoSaveStatusSoon();
      }
    } catch (_) {
      if (mounted) {
        setState(() => _videoSaveStatus = 'The video could not be saved.');
        _dismissVideoSaveStatusSoon();
      }
    } finally {
      if (mounted) setState(() => _savingVideo = false);
    }
  }

  void _dismissVideoSaveStatusSoon() {
    _videoSaveStatusTimer?.cancel();
    _videoSaveStatusTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _videoSaveStatus = null);
    });
  }

  Widget _saveVideoButton() {
    return _ScrimIconButton(
      icon: _videoSaved ? Icons.check : Icons.download,
      tooltip: _videoSaved ? 'Video saved' : 'Save video',
      loading: _savingVideo,
      onPressed: _savingVideo || _videoSaved ? null : _saveVideo,
    );
  }

  Widget _saveVideoStatusOverlay(ColorScheme colors) {
    final status = _videoSaveStatus;
    if (status == null) return const SizedBox.shrink();
    return Positioned(
      left: 8,
      right: 8,
      bottom: 8,
      child: IgnorePointer(
        child: Center(
          child: Material(
            color: colors.primaryContainer,
            elevation: 6,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_savingVideo) ...[
                    SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ] else if (_videoSaved) ...[
                    Icon(
                      Icons.check_circle,
                      size: 18,
                      color: colors.onPrimaryContainer,
                    ),
                    const SizedBox(width: 7),
                  ],
                  Flexible(
                    child: Text(
                      status,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (_controller != null || _linuxChewieController != null) {
      return SizedBox(
        width: 280,
        height: 210,
        child: Stack(
          children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Platform.isLinux
                    ? ColoredBox(
                        color: Colors.black,
                        child: Chewie(controller: _linuxChewieController!),
                      )
                    : Platform.isAndroid
                    ? Video(
                        controller: _controller!,
                        onEnterFullscreen:
                            _enterAndroidFullscreenPreservingOrientation,
                        onExitFullscreen:
                            _exitAndroidFullscreenPreservingOrientation,
                      )
                    : Video(controller: _controller!),
              ),
            ),
            Positioned(top: 4, right: 40, child: _saveVideoButton()),
            Positioned(
              top: 4,
              right: 4,
              child: _ScrimIconButton(
                icon: Icons.close,
                tooltip: 'Stop',
                onPressed: _stop,
              ),
            ),
            _saveVideoStatusOverlay(colors),
          ],
        ),
      );
    }

    final thumbnailFuture = _thumbnail;
    if (thumbnailFuture == null) {
      return _idle(null);
    }
    return FutureBuilder<MatrixFile>(
      future: thumbnailFuture,
      builder: (context, snapshot) => _idle(snapshot.data),
    );
  }

  // Renders either a decoded thumbnail image or, if the event has none (the
  // common case for videos), a generic placeholder — either way it's the
  // same tappable "play" surface. A thumbnail load failure falls back to the
  // placeholder rather than an error: the video itself is still perfectly
  // playable even when its preview image couldn't be fetched.
  Widget _idle(MatrixFile? thumbnail) {
    return Semantics(
      button: true,
      label: 'Play encrypted video',
      child: GestureDetector(
        onTap: _loadingFull ? null : _startPlayback,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: 280,
            height: 210,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (thumbnail != null)
                  Image.memory(
                    thumbnail.bytes,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  )
                else
                  const ColoredBox(
                    color: Colors.black87,
                    child: Icon(
                      Icons.videocam,
                      color: Colors.white54,
                      size: 48,
                    ),
                  ),
                Container(color: Colors.black.withValues(alpha: 0.25)),
                Center(
                  child: _loadingFull
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Icon(
                          Icons.play_circle_fill,
                          color: Colors.white,
                          size: 56,
                        ),
                ),
                Positioned(top: 4, right: 4, child: _saveVideoButton()),
                _saveVideoStatusOverlay(Theme.of(context).colorScheme),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ScrimIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool loading;
  final VoidCallback? onPressed;

  const _ScrimIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      shape: const CircleBorder(),
      child: IconButton(
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        padding: EdgeInsets.zero,
        iconSize: 18,
        color: Colors.white,
        icon: loading
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Icon(icon),
        tooltip: tooltip,
        onPressed: onPressed,
      ),
    );
  }
}
