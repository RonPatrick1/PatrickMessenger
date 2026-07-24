import 'package:flutter_test/flutter_test.dart';
import 'package:patrick_messenger/history/history_recovery_service.dart';

void main() {
  test('requires a recovery passphrase of at least 12 characters', () {
    expect(validateRecoveryPassphrase('too short'), isNotNull);
    expect(validateRecoveryPassphrase('twelve chars!'), isNull);
  });
}
