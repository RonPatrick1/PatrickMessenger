import 'dart:async';

import 'package:matrix/matrix.dart';

import '../archive/archive_contract.dart';

class PushClassificationService {
  final Client client;
  StreamSubscription<LoginState>? _loginSubscription;

  PushClassificationService(this.client);

  Future<void> initialize() async {
    _loginSubscription = client.onLoginStateChanged.stream.listen((state) {
      if (state == LoginState.loggedIn) unawaited(_tryInstallControlRule());
    });
    if (client.isLogged()) await _tryInstallControlRule();
  }

  Future<void> _tryInstallControlRule() async {
    try {
      await _installControlRule();
    } catch (_) {
      // Offline startup must not prevent access to locally cached messages.
    }
  }

  Future<void> _installControlRule() => client.setPushRule(
    PushRuleKind.override,
    controlPushRuleId,
    const [],
    conditions: [
      PushCondition(
        kind: PushRuleConditions.eventMatch.name,
        key: r'content.m\.relates_to.rel_type',
        pattern: controlRelationType,
      ),
    ],
  );

  Future<void> dispose() async {
    await _loginSubscription?.cancel();
  }
}
