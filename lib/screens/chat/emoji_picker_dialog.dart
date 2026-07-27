import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';

import 'emoji_style.dart';

const quickReactionEmojis = <String>['👍', '❤️', '😂', '😮', '😢', '😡'];

Future<String?> pickReactionEmoji(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: 360,
          maxWidth: 520,
          maxHeight: 560,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppBar(
              automaticallyImplyLeading: false,
              title: const Text('Choose a reaction'),
              actions: [
                IconButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Flexible(
              child: EmojiPicker(
                onEmojiSelected: (_, emoji) {
                  Navigator.pop(dialogContext, emoji.emoji);
                },
                config: Config(
                  height: 470,
                  emojiTextStyle: emojiGlyphStyle(),
                  emojiViewConfig: const EmojiViewConfig(columns: 9),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> showComposerEmojiPicker(
  BuildContext context,
  TextEditingController controller,
) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: 360,
          maxWidth: 520,
          maxHeight: 560,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppBar(
              automaticallyImplyLeading: false,
              title: const Text('Emoji'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Done'),
                ),
              ],
            ),
            Flexible(
              child: EmojiPicker(
                textEditingController: controller,
                config: Config(
                  height: 470,
                  emojiTextStyle: emojiGlyphStyle(),
                  emojiViewConfig: const EmojiViewConfig(columns: 9),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
