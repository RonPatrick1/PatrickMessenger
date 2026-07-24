import 'package:flutter/material.dart';

Future<String?> showRenameConversationDialog({
  required BuildContext context,
  required String initialName,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => RenameConversationDialog(initialName: initialName),
  );
}

class RenameConversationDialog extends StatefulWidget {
  final String initialName;

  const RenameConversationDialog({required this.initialName, super.key});

  @override
  State<RenameConversationDialog> createState() =>
      _RenameConversationDialogState();
}

class _RenameConversationDialogState extends State<RenameConversationDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initialName.length,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final trimmed = _controller.text.trim();
    if (trimmed.isNotEmpty) Navigator.pop(context, trimmed);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.drive_file_rename_outline),
      title: const Text('Rename conversation'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: TextField(
          controller: _controller,
          autofocus: true,
          maxLength: 100,
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (_) => _submit(),
          decoration: const InputDecoration(labelText: 'Conversation name'),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Rename')),
      ],
    );
  }
}
