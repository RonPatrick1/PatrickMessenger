import 'dart:async';

import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';

class HistoryRecoveryStatus {
  final bool initialized;
  final bool connected;

  const HistoryRecoveryStatus({
    required this.initialized,
    required this.connected,
  });
}

class HistorySyncReport {
  final int roomCount;
  final int downloadedEventCount;

  const HistorySyncReport({
    required this.roomCount,
    required this.downloadedEventCount,
  });
}

class HistorySetupResult {
  final String recoveryKey;
  final HistorySyncReport syncReport;

  const HistorySetupResult({
    required this.recoveryKey,
    required this.syncReport,
  });
}

typedef HistoryProgressCallback = void Function(String message);

String? validateRecoveryPassphrase(String passphrase) {
  if (passphrase.length < 12) {
    return 'Use a recovery passphrase with at least 12 characters.';
  }
  return null;
}

class HistoryRecoveryService {
  static final Map<Client, Future<HistorySyncReport>> _activeSyncs = {};

  final Client client;

  const HistoryRecoveryService(this.client);

  Future<HistoryRecoveryStatus> getStatus() async {
    final state = await client.getCryptoIdentityState();
    return HistoryRecoveryStatus(
      initialized: state.initialized,
      connected: state.connected,
    );
  }

  Future<HistorySetupResult> initialize({
    required String passphrase,
    required String accountPassword,
    HistoryProgressCallback? onProgress,
  }) async {
    final passphraseError = validateRecoveryPassphrase(passphrase);
    if (passphraseError != null) throw FormatException(passphraseError);
    if (accountPassword.isEmpty) {
      throw const FormatException('Enter your Matrix account password.');
    }
    final state = await getStatus();
    if (state.initialized) {
      throw StateError('Encrypted history recovery is already initialized.');
    }

    onProgress?.call('Creating encrypted history recovery…');
    final recoveryKey = await _initializeCryptoIdentity(
      passphrase: passphrase,
      accountPassword: accountPassword,
    );
    final report = await syncAllHistory(onProgress: onProgress);
    return HistorySetupResult(recoveryKey: recoveryKey, syncReport: report);
  }

  Future<String> _initializeCryptoIdentity({
    required String passphrase,
    required String accountPassword,
  }) async {
    final userId = client.userID;
    if (userId == null) {
      throw StateError('The Matrix account is not signed in.');
    }

    final activeRequests = <UiaRequest>{};
    late final StreamSubscription<UiaRequest> subscription;
    subscription = client.onUiaRequest.stream.listen((request) {
      if (!activeRequests.add(request)) return;
      unawaited(
        _authorizeWithPassword(
          request: request,
          accountPassword: accountPassword,
          userId: userId,
        ).whenComplete(() => activeRequests.remove(request)),
      );
    });

    try {
      return await client.initCryptoIdentity(
        passphrase: passphrase,
        keyName: 'Patrick Messenger history recovery',
      );
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> _authorizeWithPassword({
    required UiaRequest request,
    required String accountPassword,
    required String userId,
  }) async {
    while (request.state == UiaRequestState.waitForUser) {
      if (!request.nextStages.contains(AuthenticationTypes.password)) {
        request.cancel(
          Exception(
            'The server requested an unsupported account-verification method.',
          ),
        );
        return;
      }
      await request.completeStage(
        AuthenticationPassword(
          session: request.session,
          password: accountPassword,
          identifier: AuthenticationUserIdentifier(user: userId),
        ),
      );
    }
  }

  Future<HistorySyncReport> restore({
    required String recoverySecret,
    HistoryProgressCallback? onProgress,
  }) async {
    if (recoverySecret.trim().isEmpty) {
      throw const FormatException('Enter the recovery passphrase or key.');
    }
    final state = await getStatus();
    if (!state.initialized) {
      throw StateError('Encrypted history recovery has not been initialized.');
    }
    if (!state.connected) {
      onProgress?.call('Unlocking encrypted history backup…');
      await client.restoreCryptoIdentity(recoverySecret.trim());
    }
    return syncAllHistory(onProgress: onProgress);
  }

  Future<HistorySyncReport> syncAllHistory({
    HistoryProgressCallback? onProgress,
  }) async {
    final active = _activeSyncs[client];
    if (active != null) {
      onProgress?.call('History synchronization is already in progress…');
      return active;
    }

    final sync = _syncAllHistory(onProgress: onProgress);
    _activeSyncs[client] = sync;
    try {
      return await sync;
    } finally {
      if (identical(_activeSyncs[client], sync)) {
        _activeSyncs.remove(client);
      }
    }
  }

  Future<HistorySyncReport> _syncAllHistory({
    HistoryProgressCallback? onProgress,
  }) async {
    final encryption = client.encryption;
    if (encryption == null) {
      throw StateError('End-to-end encryption is unavailable.');
    }

    onProgress?.call('Uploading this device’s encrypted history keys…');
    await encryption.keyManager.uploadInboundGroupSessions();

    if (await encryption.keyManager.isCached()) {
      onProgress?.call('Downloading encrypted history keys…');
      await encryption.keyManager.loadAllKeys();
    }

    final rooms = client.rooms
        .where((room) => room.membership == Membership.join && room.encrypted)
        .toList();
    var downloadedEvents = 0;

    for (var index = 0; index < rooms.length; index++) {
      final room = rooms[index];
      onProgress?.call(
        'Downloading history for ${room.getLocalizedDisplayname()} '
        '(${index + 1} of ${rooms.length})…',
      );
      await room.postLoad();
      var batches = 0;
      while (room.prev_batch != null) {
        final previousToken = room.prev_batch;
        final count = await room.requestHistory(historyCount: 100);
        downloadedEvents += count;
        batches++;
        // Synapse can return an empty filtered batch while still advancing the
        // pagination token. Continue until the token stops or reaches the
        // beginning of the room.
        if (room.prev_batch == previousToken) break;
        if (batches >= 10000) {
          throw StateError('History pagination exceeded its safety limit.');
        }
      }
    }

    onProgress?.call('Finishing encrypted history backup…');
    await encryption.keyManager.uploadInboundGroupSessions();
    onProgress?.call('History is synchronized.');
    return HistorySyncReport(
      roomCount: rooms.length,
      downloadedEventCount: downloadedEvents,
    );
  }
}
