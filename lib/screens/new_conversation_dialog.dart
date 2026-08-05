import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../config/app_config.dart';
import '../matrix/user_directory_resolver.dart';

/// The people (and optional group name) chosen in [NewConversationDialog].
class NewConversationResult {
  final List<Profile> recipients;
  final String? groupName;

  const NewConversationResult({required this.recipients, this.groupName});
}

/// Picks one or more accounts by name/username, resolving each via the user
/// directory before it's added as a removable chip. Reused both for
/// starting a brand new conversation (where 2+ picks becomes a group, with
/// an optional name field) and for inviting more people into a conversation
/// already in progress (where [allowGroupName] is turned off, since the
/// room already has whatever name it has).
class NewConversationDialog extends StatefulWidget {
  final Client client;
  final AppConfig config;
  final String title;
  final String? groupTitle;
  final bool allowGroupName;
  final String confirmLabel;

  const NewConversationDialog({
    required this.client,
    required this.config,
    this.title = 'New encrypted conversation',
    this.groupTitle = 'New group',
    this.allowGroupName = true,
    this.confirmLabel = 'Create',
    super.key,
  });

  @override
  State<NewConversationDialog> createState() => _NewConversationDialogState();
}

class _NewConversationDialogState extends State<NewConversationDialog> {
  final _controller = TextEditingController();
  final _groupNameController = TextEditingController();
  final List<Profile> _recipients = [];
  String? _error;
  bool _resolving = false;

  @override
  void dispose() {
    _controller.dispose();
    _groupNameController.dispose();
    super.dispose();
  }

  Future<void> _addRecipient() async {
    final input = _controller.text.trim();
    if (input.isEmpty || _resolving) return;
    setState(() {
      _resolving = true;
      _error = null;
    });
    try {
      final profile = await UserDirectoryResolver(
        client: widget.client,
        config: widget.config,
      ).resolve(input);
      if (_recipients.any((existing) => existing.userId == profile.userId)) {
        setState(() => _error = 'That person is already added.');
        return;
      }
      setState(() {
        _recipients.add(profile);
        _controller.clear();
      });
    } on UserDirectoryResolutionException catch (error) {
      setState(() => _error = error.message);
    } catch (_) {
      setState(() => _error = 'That account could not be looked up.');
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  void _removeRecipient(Profile profile) {
    setState(
      () => _recipients.removeWhere(
        (existing) => existing.userId == profile.userId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isGroup = _recipients.length > 1;
    final groupTitle = widget.groupTitle;
    return AlertDialog(
      title: Text(isGroup && groupTitle != null ? groupTitle : widget.title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_recipients.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final profile in _recipients)
                      InputChip(
                        label: Text(
                          profile.displayName ??
                              profile.userId.localpart ??
                              profile.userId,
                        ),
                        onDeleted: () => _removeRecipient(profile),
                      ),
                  ],
                ),
              ),
            TextField(
              controller: _controller,
              autofocus: true,
              autocorrect: false,
              enabled: !_resolving,
              onSubmitted: (_) => _addRecipient(),
              decoration: InputDecoration(
                labelText: 'Name or username',
                helperText: _recipients.isEmpty
                    ? 'For example: Ron Patrick or ron_patrick'
                    : 'Add another person, or tap ${widget.confirmLabel} '
                          'when done.',
                helperMaxLines: 2,
                errorText: _error,
                suffixIcon: _resolving
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        icon: const Icon(Icons.add),
                        tooltip: 'Add',
                        onPressed: _addRecipient,
                      ),
              ),
            ),
            if (isGroup && widget.allowGroupName) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _groupNameController,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Group name (optional)',
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _recipients.isEmpty
              ? null
              : () => Navigator.pop(
                  context,
                  NewConversationResult(
                    recipients: List.of(_recipients),
                    groupName: _groupNameController.text.trim().isEmpty
                        ? null
                        : _groupNameController.text.trim(),
                  ),
                ),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
