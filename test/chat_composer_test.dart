import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrick_messenger/screens/chat/chat_composer.dart';

void main() {
  test('Ask Liam prefixes the existing composer draft', () {
    const original = TextEditingValue(
      text: 'What happened?',
      selection: TextSelection.collapsed(offset: 5),
    );

    final prepared = withLiamPrefix(original);

    expect(prepared.text, 'Liam: What happened?');
    expect(prepared.selection.baseOffset, 11);
    expect(withLiamPrefix(prepared), prepared);
  });

  group('composerEnterAction', () {
    test('Enter sends on Ubuntu desktop', () {
      expect(
        composerEnterAction(
          platform: TargetPlatform.linux,
          controlPressed: false,
        ),
        ComposerEnterAction.send,
      );
    });

    test('Control+Enter inserts a newline on Ubuntu desktop', () {
      expect(
        composerEnterAction(
          platform: TargetPlatform.linux,
          controlPressed: true,
        ),
        ComposerEnterAction.insertNewline,
      );
    });

    test('Shift+Enter inserts a newline on Ubuntu desktop', () {
      expect(
        composerEnterAction(
          platform: TargetPlatform.linux,
          controlPressed: false,
          shiftPressed: true,
        ),
        ComposerEnterAction.insertNewline,
      );
    });

    test('iOS hardware Enter sends and Control+Enter inserts a newline', () {
      expect(
        composerEnterAction(
          platform: TargetPlatform.iOS,
          controlPressed: false,
        ),
        ComposerEnterAction.send,
      );
      expect(
        composerEnterAction(platform: TargetPlatform.iOS, controlPressed: true),
        ComposerEnterAction.insertNewline,
      );
    });

    test('Android hardware Enter sends and Shift+Enter inserts a newline', () {
      expect(
        composerEnterAction(
          platform: TargetPlatform.android,
          controlPressed: false,
        ),
        ComposerEnterAction.send,
      );
      expect(
        composerEnterAction(
          platform: TargetPlatform.android,
          controlPressed: false,
          shiftPressed: true,
        ),
        ComposerEnterAction.insertNewline,
      );
    });
  });

  testWidgets('desktop Enter sends from the message field', (tester) async {
    var sends = 0;
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.linux),
        home: Scaffold(
          body: ChatComposer(
            controller: controller,
            sendingAttachment: false,
            contextLabel: null,
            contextPreview: null,
            onCancelContext: () {},
            onSend: () => sends++,
            onPaste: () {},
            onEmoji: () {},
            onAttachment: (_) {},
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'Hello');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);

    expect(sends, 1);
    expect(controller.text, 'Hello');
  });

  testWidgets('desktop Control+Enter inserts a newline', (tester) async {
    var sends = 0;
    final controller = TextEditingController(text: 'Hello');
    controller.selection = const TextSelection.collapsed(offset: 5);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.linux),
        home: Scaffold(
          body: ChatComposer(
            controller: controller,
            sendingAttachment: false,
            contextLabel: null,
            contextPreview: null,
            onCancelContext: () {},
            onSend: () => sends++,
            onPaste: () {},
            onEmoji: () {},
            onAttachment: (_) {},
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    expect(sends, 0);
    expect(controller.text, 'Hello\n');
  });

  testWidgets('desktop Shift+Enter inserts a newline', (tester) async {
    var sends = 0;
    final controller = TextEditingController(text: 'Hello');
    controller.selection = const TextSelection.collapsed(offset: 5);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.linux),
        home: Scaffold(
          body: ChatComposer(
            controller: controller,
            sendingAttachment: false,
            contextLabel: null,
            contextPreview: null,
            onCancelContext: () {},
            onSend: () => sends++,
            onPaste: () {},
            onEmoji: () {},
            onAttachment: (_) {},
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    expect(sends, 0);
    expect(controller.text, 'Hello\n');
  });

  testWidgets('iOS simulator hardware Enter sends', (tester) async {
    var sends = 0;
    final controller = TextEditingController(text: 'Hello from iPhone');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: Scaffold(
          body: ChatComposer(
            controller: controller,
            sendingAttachment: false,
            contextLabel: null,
            contextPreview: null,
            onCancelContext: () {},
            onSend: () => sends++,
            onPaste: () {},
            onEmoji: () {},
            onAttachment: (_) {},
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);

    expect(sends, 1);
    expect(controller.text, 'Hello from iPhone');
  });

  testWidgets('Control+V delegates paste to the chat', (tester) async {
    var pastes = 0;
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.linux),
        home: Scaffold(
          body: ChatComposer(
            controller: controller,
            sendingAttachment: false,
            contextLabel: null,
            contextPreview: null,
            onCancelContext: () {},
            onSend: () {},
            onPaste: () => pastes++,
            onEmoji: () {},
            onAttachment: (_) {},
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    expect(pastes, 1);
  });

  testWidgets('attachment menu includes Ask Liam', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            controller: controller,
            sendingAttachment: false,
            contextLabel: null,
            contextPreview: null,
            onCancelContext: () {},
            onSend: () {},
            onPaste: () {},
            onEmoji: () {},
            onAttachment: (_) {},
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Attach'));
    await tester.pumpAndSettle();

    expect(find.text('Ask Liam'), findsOneWidget);
    expect(find.text('Remove Liam'), findsNothing);
  });

  testWidgets('joined rooms offer to remove Liam', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            controller: controller,
            sendingAttachment: false,
            liamJoined: true,
            contextLabel: null,
            contextPreview: null,
            onCancelContext: () {},
            onSend: () {},
            onPaste: () {},
            onEmoji: () {},
            onAttachment: (_) {},
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Attach'));
    await tester.pumpAndSettle();

    expect(find.text('Remove Liam'), findsOneWidget);
  });
}
