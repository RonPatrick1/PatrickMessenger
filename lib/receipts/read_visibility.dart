import 'package:flutter/widgets.dart';

/// Read markers describe messages the user could actually see, not merely
/// messages synchronized by a client whose window is hidden or unfocused.
bool shouldMarkConversationRead({
  required AppLifecycleState lifecycleState,
  required bool routeIsCurrent,
  required bool desktopWindowFocused,
}) {
  return lifecycleState == AppLifecycleState.resumed &&
      routeIsCurrent &&
      desktopWindowFocused;
}
