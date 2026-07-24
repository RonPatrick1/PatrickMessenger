import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../matrix/display_names.dart';
import '../notifications/message_notification_service.dart';
import '../notifications/notification_preferences.dart';

Future<void> showAccountSettingsDialog({
  required BuildContext context,
  required Client client,
  required NotificationPreferenceController notificationController,
  required MessageNotificationService notificationService,
}) async {
  final userId = client.userID;
  if (userId == null) return;

  String? currentDisplayName;
  try {
    currentDisplayName = (await client.fetchOwnProfile()).displayName;
  } catch (_) {
    // The Matrix ID still provides a useful initial value while offline.
  }
  if (!context.mounted) return;

  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => _AccountSettingsDialog(
      client: client,
      userId: userId,
      initialName: readableMatrixProfileName(
        userId: userId,
        displayName: currentDisplayName,
      ),
      notificationController: notificationController,
      notificationService: notificationService,
    ),
  );
  if (saved == true && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Account settings saved.')));
  }
}

class _AccountSettingsDialog extends StatefulWidget {
  final Client client;
  final String userId;
  final String initialName;
  final NotificationPreferenceController notificationController;
  final MessageNotificationService notificationService;

  const _AccountSettingsDialog({
    required this.client,
    required this.userId,
    required this.initialName,
    required this.notificationController,
    required this.notificationService,
  });

  @override
  State<_AccountSettingsDialog> createState() => _AccountSettingsDialogState();
}

class _AccountSettingsDialogState extends State<_AccountSettingsDialog> {
  late final TextEditingController _controller;
  late bool _notificationsEnabled;
  late bool _soundEnabled;
  late bool _showPreviews;
  bool _saving = false;
  bool _testing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initialName.length,
    );
    _notificationsEnabled = widget.notificationController.enabled;
    _soundEnabled = widget.notificationController.soundEnabled;
    _showPreviews = widget.notificationController.showPreviews;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<bool> _ensureNotificationPermission() async {
    if (!_notificationsEnabled) return true;
    final allowed = await widget.notificationService.requestPermission(
      sound: _soundEnabled,
    );
    if (!allowed && mounted) {
      setState(() {
        _error =
            'Notifications are blocked by this device. Enable them in '
            'the operating system settings, then try again.';
      });
    }
    return allowed;
  }

  Future<void> _testNotification() async {
    setState(() {
      _testing = true;
      _error = null;
    });
    try {
      if (!await _ensureNotificationPermission()) return;
      await widget.notificationService.showTestNotification(
        sound: _soundEnabled,
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'A test notification could not be shown on this device.';
        });
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    final name = _controller.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter the name people should see.');
      return;
    }
    if (name.length > 80) {
      setState(() => _error = 'Use 80 characters or fewer.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (!await _ensureNotificationPermission()) return;
      if (name != widget.initialName) {
        await widget.client.setProfileField(widget.userId, 'displayname', {
          'displayname': name,
        });
      }
      await widget.notificationController.update(
        enabled: _notificationsEnabled,
        soundEnabled: _soundEnabled,
        showPreviews: _showPreviews,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'The account settings could not be saved.';
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _saving || _testing;
    return AlertDialog(
      icon: const Icon(Icons.manage_accounts_outlined),
      title: const Text('Account settings'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Your human-friendly name appears in conversations. Your '
                'permanent Matrix account ID does not change.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _controller,
                autofocus: true,
                enabled: !busy,
                textCapitalization: TextCapitalization.words,
                maxLength: 80,
                onSubmitted: (_) => _save(),
                decoration: const InputDecoration(labelText: 'Display name'),
              ),
              Text(widget.userId, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 20),
              const Divider(),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.notifications_outlined),
                title: const Text('Message notifications'),
                subtitle: const Text(
                  'Show a notification when a new message arrives.',
                ),
                value: _notificationsEnabled,
                onChanged: busy
                    ? null
                    : (value) => setState(() => _notificationsEnabled = value),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.volume_up_outlined),
                title: const Text('Notification sound'),
                subtitle: Text(
                  _soundEnabled ? 'Use the system default sound.' : 'Silent.',
                ),
                value: _soundEnabled,
                onChanged: busy || !_notificationsEnabled
                    ? null
                    : (value) => setState(() => _soundEnabled = value),
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.visibility_outlined),
                title: const Text('Message previews'),
                subtitle: const Text(
                  'Show the sender and message text in notifications. Off is '
                  'safer on a lock screen.',
                ),
                value: _showPreviews,
                onChanged: busy || !_notificationsEnabled
                    ? null
                    : (value) => setState(() => _showPreviews = value),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: busy || !_notificationsEnabled
                      ? null
                      : _testNotification,
                  icon: const Icon(Icons.notification_add_outlined),
                  label: Text(
                    _testing ? 'Sending test…' : 'Send test notification',
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: busy ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
    );
  }
}
