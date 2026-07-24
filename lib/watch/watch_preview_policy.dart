enum WatchPlatform { appleWatch, wearOs }

class WatchState {
  final WatchPlatform platform;
  final bool paired;
  final bool verified;
  final bool locked;
  final bool onWrist;

  const WatchState({
    required this.platform,
    required this.paired,
    required this.verified,
    required this.locked,
    required this.onWrist,
  });
}

enum WatchPreviewKind { suppress, genericNotification, decryptedThumbnail }

/// The privacy rule shared by the future watchOS and Wear OS companions.
///
/// A watch may receive a decrypted thumbnail only after it has been paired,
/// verified, unlocked, and detected on the owner's wrist. All other connected
/// states receive a content-free notification.
WatchPreviewKind decideWatchPreview(WatchState state) {
  if (!state.paired || !state.verified) {
    return WatchPreviewKind.suppress;
  }
  if (state.locked || !state.onWrist) {
    return WatchPreviewKind.genericNotification;
  }
  return WatchPreviewKind.decryptedThumbnail;
}
