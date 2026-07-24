import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';

import '../history/history_recovery_service.dart';

Future<void> showHistoryRecoveryDialog({
  required BuildContext context,
  required Client client,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _HistoryRecoveryDialog(client: client),
  );
}

class HistoryRecoveryBanner extends StatefulWidget {
  final Client client;

  const HistoryRecoveryBanner({required this.client, super.key});

  @override
  State<HistoryRecoveryBanner> createState() => _HistoryRecoveryBannerState();
}

class _HistoryRecoveryBannerState extends State<HistoryRecoveryBanner> {
  late Future<HistoryRecoveryStatus> _status;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _status = HistoryRecoveryService(widget.client).getStatus();
    unawaited(_syncIfConnected());
  }

  Future<void> _syncIfConnected() async {
    try {
      final status = await _status;
      if (status.connected) {
        await HistoryRecoveryService(widget.client).syncAllHistory();
      }
    } catch (_) {
      // The manual History Sync screen exposes errors and retry controls.
    }
  }

  Future<void> _open() async {
    await showHistoryRecoveryDialog(context: context, client: widget.client);
    if (mounted) setState(_reload);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<HistoryRecoveryStatus>(
      future: _status,
      builder: (context, snapshot) {
        final status = snapshot.data;
        if (status == null || status.connected) {
          return const SizedBox.shrink();
        }
        final initialized = status.initialized;
        final colors = Theme.of(context).colorScheme;
        return Card(
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          color: colors.secondaryContainer,
          child: ListTile(
            leading: Icon(
              initialized ? Icons.history_toggle_off : Icons.cloud_off_outlined,
              color: colors.onSecondaryContainer,
            ),
            title: Text(
              initialized
                  ? 'Restore encrypted message history'
                  : 'Turn on encrypted history sync',
            ),
            subtitle: Text(
              initialized
                  ? 'Unlock this device with your recovery passphrase or key.'
                  : 'Keep old messages available when you add a new device.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _open,
          ),
        );
      },
    );
  }
}

class _HistoryRecoveryDialog extends StatefulWidget {
  final Client client;

  const _HistoryRecoveryDialog({required this.client});

  @override
  State<_HistoryRecoveryDialog> createState() => _HistoryRecoveryDialogState();
}

class _HistoryRecoveryDialogState extends State<_HistoryRecoveryDialog> {
  final _accountPasswordController = TextEditingController();
  final _passphraseController = TextEditingController();
  final _confirmationController = TextEditingController();
  late final HistoryRecoveryService _service;
  late Future<HistoryRecoveryStatus> _status;

  bool _busy = false;
  bool _obscure = true;
  String? _progress;
  String? _error;
  String? _recoveryKey;
  HistorySyncReport? _report;

  @override
  void initState() {
    super.initState();
    _service = HistoryRecoveryService(widget.client);
    _status = _service.getStatus();
  }

  @override
  void dispose() {
    _accountPasswordController.dispose();
    _passphraseController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  void _setProgress(String progress) {
    if (mounted) setState(() => _progress = progress);
  }

  Future<void> _initialize() async {
    final passphrase = _passphraseController.text;
    if (passphrase != _confirmationController.text) {
      setState(() => _error = 'The recovery passphrases do not match.');
      return;
    }
    await _run(() async {
      final result = await _service.initialize(
        passphrase: passphrase,
        accountPassword: _accountPasswordController.text,
        onProgress: _setProgress,
      );
      _recoveryKey = result.recoveryKey;
      _report = result.syncReport;
      _status = Future.value(
        const HistoryRecoveryStatus(initialized: true, connected: true),
      );
      _accountPasswordController.clear();
      _passphraseController.clear();
      _confirmationController.clear();
    });
  }

  Future<void> _restore() async {
    await _run(() async {
      _report = await _service.restore(
        recoverySecret: _passphraseController.text,
        onProgress: _setProgress,
      );
      _status = Future.value(
        const HistoryRecoveryStatus(initialized: true, connected: true),
      );
      _passphraseController.clear();
    });
  }

  Future<void> _sync() async {
    await _run(() async {
      _report = await _service.syncAllHistory(onProgress: _setProgress);
    });
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _report = null;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = switch (error) {
            FormatException(:final message) => message.toString(),
            StateError(:final message) => message,
            _ =>
              'History synchronization failed. Check the account password, '
                  'recovery passphrase/key, and server connection, then try '
                  'again.',
          };
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _copyRecoveryKey() async {
    final recoveryKey = _recoveryKey;
    if (recoveryKey == null) return;
    await Clipboard.setData(ClipboardData(text: recoveryKey));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Recovery key copied.')));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.history),
      title: const Text('Encrypted message history'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          child: FutureBuilder<HistoryRecoveryStatus>(
            future: _status,
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const SizedBox(
                  height: 180,
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              return _buildContent(snapshot.data!);
            },
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _buildContent(HistoryRecoveryStatus status) {
    if (_recoveryKey != null) return _buildRecoveryKey();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Your server stores encrypted messages and encrypted room-key '
          'backups. Only your recovery passphrase or recovery key can unlock '
          'the history on a new device.',
        ),
        const SizedBox(height: 18),
        if (!status.initialized) ...[
          Text(
            'Turn on history sync',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          const Text(
            'Choose a separate recovery passphrase and save it somewhere '
            'safe. Each person configures recovery for their own '
            'account.',
          ),
          const SizedBox(height: 14),
          _secretField(
            controller: _accountPasswordController,
            label: 'Matrix account password',
          ),
          const SizedBox(height: 6),
          const Text('Used once to authorize recovery setup. It is not saved.'),
          const SizedBox(height: 12),
          _secretField(
            controller: _passphraseController,
            label: 'Recovery passphrase',
          ),
          const SizedBox(height: 12),
          _secretField(
            controller: _confirmationController,
            label: 'Confirm recovery passphrase',
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _initialize,
            icon: const Icon(Icons.cloud_upload_outlined),
            label: const Text('Turn on and sync history'),
          ),
        ] else if (!status.connected) ...[
          Text(
            'Unlock history on this device',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          const Text(
            'Enter the recovery passphrase or recovery key created on an '
            'existing device.',
          ),
          const SizedBox(height: 14),
          _secretField(
            controller: _passphraseController,
            label: 'Recovery passphrase or key',
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _restore,
            icon: const Icon(Icons.lock_open_outlined),
            label: const Text('Restore and download history'),
          ),
        ] else ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.cloud_done_outlined),
            title: const Text('Encrypted history sync is active'),
            subtitle: const Text(
              'This device can upload and restore encrypted message keys.',
            ),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _busy ? null : _sync,
            icon: const Icon(Icons.sync),
            label: const Text('Sync complete history now'),
          ),
        ],
        if (_busy) ...[
          const SizedBox(height: 18),
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Text(_progress ?? 'Working…'),
        ],
        if (_error != null) ...[
          const SizedBox(height: 14),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (_report != null) ...[
          const SizedBox(height: 14),
          Text(
            'Synchronized ${_report!.roomCount} encrypted conversation(s); '
            'downloaded ${_report!.downloadedEventCount} older event(s).',
          ),
        ],
      ],
    );
  }

  Widget _buildRecoveryKey() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Save this recovery key',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        const Text(
          'Your recovery passphrase can restore history. This key is an '
          'additional fallback. Store it in a password manager; it will not '
          'be shown again.',
        ),
        const SizedBox(height: 14),
        DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: SelectionArea(child: Text(_recoveryKey!)),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _copyRecoveryKey,
          icon: const Icon(Icons.copy),
          label: const Text('Copy recovery key'),
        ),
        if (_report != null) ...[
          const SizedBox(height: 14),
          Text(
            'History sync is active for ${_report!.roomCount} '
            'conversation(s).',
          ),
        ],
      ],
    );
  }

  Widget _secretField({
    required TextEditingController controller,
    required String label,
  }) {
    return TextField(
      controller: controller,
      obscureText: _obscure,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: IconButton(
          onPressed: () => setState(() => _obscure = !_obscure),
          tooltip: _obscure ? 'Show' : 'Hide',
          icon: Icon(
            _obscure
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
          ),
        ),
      ),
    );
  }
}
