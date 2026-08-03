import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrick_messenger/receipts/read_visibility.dart';

void main() {
  test('marks read only while the conversation is actually visible', () {
    expect(
      shouldMarkConversationRead(
        lifecycleState: AppLifecycleState.resumed,
        routeIsCurrent: true,
        desktopWindowFocused: true,
      ),
      isTrue,
    );
    expect(
      shouldMarkConversationRead(
        lifecycleState: AppLifecycleState.paused,
        routeIsCurrent: true,
        desktopWindowFocused: true,
      ),
      isFalse,
    );
    expect(
      shouldMarkConversationRead(
        lifecycleState: AppLifecycleState.resumed,
        routeIsCurrent: false,
        desktopWindowFocused: true,
      ),
      isFalse,
    );
    expect(
      shouldMarkConversationRead(
        lifecycleState: AppLifecycleState.resumed,
        routeIsCurrent: true,
        desktopWindowFocused: false,
      ),
      isFalse,
    );
  });
}
