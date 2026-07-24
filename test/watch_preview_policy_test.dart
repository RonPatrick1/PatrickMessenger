import 'package:flutter_test/flutter_test.dart';
import 'package:patrick_messenger/watch/watch_preview_policy.dart';

void main() {
  for (final platform in WatchPlatform.values) {
    group(platform.name, () {
      test('shows a thumbnail only when verified, unlocked, and on wrist', () {
        final result = decideWatchPreview(
          WatchState(
            platform: platform,
            paired: true,
            verified: true,
            locked: false,
            onWrist: true,
          ),
        );

        expect(result, WatchPreviewKind.decryptedThumbnail);
      });

      test('hides content while locked', () {
        final result = decideWatchPreview(
          WatchState(
            platform: platform,
            paired: true,
            verified: true,
            locked: true,
            onWrist: true,
          ),
        );

        expect(result, WatchPreviewKind.genericNotification);
      });

      test('suppresses an unverified watch', () {
        final result = decideWatchPreview(
          WatchState(
            platform: platform,
            paired: true,
            verified: false,
            locked: false,
            onWrist: true,
          ),
        );

        expect(result, WatchPreviewKind.suppress);
      });
    });
  }
}
