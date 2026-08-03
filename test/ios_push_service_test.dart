import 'package:flutter_test/flutter_test.dart';
import 'package:patrick_messenger/notifications/ios_push_service.dart';

void main() {
  test('APNs payload always includes a badge fallback', () {
    final payload = buildIosPushApsPayload(soundEnabled: false);

    expect(payload['badge'], 1);
    expect(payload['mutable-content'], 1);
    expect(payload['content-available'], 1);
    expect(payload, isNot(contains('sound')));
  });

  test('APNs payload includes sound only when enabled', () {
    expect(buildIosPushApsPayload(soundEnabled: true)['sound'], 'default');
  });
}
