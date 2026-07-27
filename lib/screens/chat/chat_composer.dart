import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'emoji_style.dart';
import 'liam_icon.dart';

enum AttachmentKind {
  askLiam,
  removeLiam,
  addSharedSearch,
  rebuildSharedSearch,
  removeSharedSearch,
  picture,
  pastePicture,
  gifSearch,
}

enum ComposerEnterAction { ignore, send, insertNewline }

TextEditingValue withLiamPrefix(TextEditingValue value) {
  if (RegExp(r'^\s*liam\s*:', caseSensitive: false).hasMatch(value.text)) {
    return value;
  }

  const prefix = 'Liam: ';
  final selection = value.selection.isValid
      ? value.selection
      : TextSelection.collapsed(offset: value.text.length);
  return value.copyWith(
    text: '$prefix${value.text}',
    selection: TextSelection(
      baseOffset: selection.baseOffset + prefix.length,
      extentOffset: selection.extentOffset + prefix.length,
    ),
    composing: TextRange.empty,
  );
}

ComposerEnterAction composerEnterAction({
  required TargetPlatform platform,
  required bool controlPressed,
}) {
  final sendFromHardwareKeyboard =
      platform == TargetPlatform.linux ||
      platform == TargetPlatform.macOS ||
      platform == TargetPlatform.windows ||
      platform == TargetPlatform.iOS;
  if (!sendFromHardwareKeyboard) return ComposerEnterAction.ignore;
  return controlPressed
      ? ComposerEnterAction.insertNewline
      : ComposerEnterAction.send;
}

class ChatComposer extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool sendingAttachment;
  final bool liamJoined;
  final bool sharedSearchJoined;
  final String? contextLabel;
  final String? contextPreview;
  final VoidCallback onCancelContext;
  final VoidCallback onSend;
  final VoidCallback onPaste;
  final VoidCallback onEmoji;
  final VoidCallback? onCamera;
  final ValueChanged<AttachmentKind> onAttachment;

  const ChatComposer({
    required this.controller,
    this.focusNode,
    required this.sendingAttachment,
    this.liamJoined = false,
    this.sharedSearchJoined = false,
    required this.contextLabel,
    required this.contextPreview,
    required this.onCancelContext,
    required this.onSend,
    required this.onPaste,
    required this.onEmoji,
    this.onCamera,
    required this.onAttachment,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final mobile =
        Theme.of(context).platform == TargetPlatform.iOS ||
        Theme.of(context).platform == TargetPlatform.android;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        border: Border(top: BorderSide(color: colors.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (contextLabel != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(14, 8, 8, 4),
                child: Row(
                  children: [
                    Container(
                      width: 3,
                      height: 38,
                      decoration: BoxDecoration(
                        color: colors.primary,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            contextLabel!,
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(
                                  color: colors.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          ColorEmojiText(
                            contextPreview ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: onCancelContext,
                      tooltip: 'Cancel',
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 7, 8, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (sendingAttachment)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else
                    PopupMenuButton<AttachmentKind>(
                      tooltip: 'Attach',
                      icon: const Icon(Icons.add_circle_outline),
                      onSelected: onAttachment,
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: AttachmentKind.askLiam,
                          child: ListTile(
                            leading: LiamIcon(size: 32),
                            title: Text('Ask Liam'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        if (liamJoined)
                          const PopupMenuItem(
                            value: AttachmentKind.removeLiam,
                            child: ListTile(
                              leading: Icon(Icons.person_remove_outlined),
                              title: Text('Remove Liam'),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        if (!sharedSearchJoined)
                          const PopupMenuItem(
                            value: AttachmentKind.addSharedSearch,
                            child: ListTile(
                              leading: Icon(Icons.manage_search_outlined),
                              title: Text('Add shared search'),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        if (sharedSearchJoined) ...[
                          const PopupMenuItem(
                            value: AttachmentKind.rebuildSharedSearch,
                            child: ListTile(
                              leading: Icon(Icons.sync_outlined),
                              title: Text('Rebuild shared search'),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                          const PopupMenuItem(
                            value: AttachmentKind.removeSharedSearch,
                            child: ListTile(
                              leading: Icon(Icons.person_remove_outlined),
                              title: Text('Remove shared search'),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        ],
                        const PopupMenuItem(
                          value: AttachmentKind.picture,
                          child: ListTile(
                            leading: Icon(Icons.photo_outlined),
                            title: Text('Picture'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        const PopupMenuItem(
                          value: AttachmentKind.pastePicture,
                          child: ListTile(
                            leading: Icon(Icons.content_paste_outlined),
                            title: Text('Paste picture'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        const PopupMenuItem(
                          value: AttachmentKind.gifSearch,
                          child: ListTile(
                            leading: Icon(Icons.gif_box_outlined),
                            title: Text('Search GIPHY'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ],
                    ),
                  IconButton(
                    onPressed: onEmoji,
                    tooltip: 'Emoji',
                    icon: const Icon(Icons.emoji_emotions_outlined),
                  ),
                  if (mobile && onCamera != null)
                    IconButton(
                      onPressed: sendingAttachment ? null : onCamera,
                      tooltip: 'Take picture',
                      icon: const Icon(Icons.camera_alt_outlined),
                    ),
                  Expanded(
                    child: Focus(
                      onKeyEvent: (_, event) =>
                          _handleKeyEvent(context: context, event: event),
                      child: TextField(
                        controller: controller,
                        focusNode: focusNode,
                        minLines: 1,
                        maxLines: 5,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(
                          hintText: contextLabel?.startsWith('Editing') == true
                              ? 'Edit message'
                              : 'Message',
                          isDense: true,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton.filled(
                    onPressed: onSend,
                    tooltip: contextLabel?.startsWith('Editing') == true
                        ? 'Save edit'
                        : 'Send message',
                    icon: Icon(
                      contextLabel?.startsWith('Editing') == true
                          ? Icons.check
                          : Icons.send,
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

  KeyEventResult _handleKeyEvent({
    required BuildContext context,
    required KeyEvent event,
  }) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final pastePressed =
        event.logicalKey == LogicalKeyboardKey.keyV &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed);
    if (pastePressed) {
      onPaste();
      return KeyEventResult.handled;
    }

    if ((event.logicalKey != LogicalKeyboardKey.enter &&
        event.logicalKey != LogicalKeyboardKey.numpadEnter)) {
      return KeyEventResult.ignored;
    }

    final action = composerEnterAction(
      platform: Theme.of(context).platform,
      controlPressed: HardwareKeyboard.instance.isControlPressed,
    );
    switch (action) {
      case ComposerEnterAction.ignore:
        return KeyEventResult.ignored;
      case ComposerEnterAction.send:
        onSend();
        return KeyEventResult.handled;
      case ComposerEnterAction.insertNewline:
        _insertNewline();
        return KeyEventResult.handled;
    }
  }

  void _insertNewline() {
    final value = controller.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final start = selection.start.clamp(0, value.text.length);
    final end = selection.end.clamp(0, value.text.length);
    final text = value.text.replaceRange(start, end, '\n');
    controller.value = value.copyWith(
      text: text,
      selection: TextSelection.collapsed(offset: start + 1),
      composing: TextRange.empty,
    );
  }
}
