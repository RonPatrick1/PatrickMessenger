import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrick_messenger/screens/chat/rename_conversation_dialog.dart';

void main() {
  testWidgets('submits a trimmed name and disposes without framework errors', (
    tester,
  ) async {
    String? renamedTo;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                renamedTo = await showRenameConversationDialog(
                  context: context,
                  initialName: 'Old name',
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  Family chat  ');
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    expect(renamedTo, 'Family chat');
    expect(find.byType(RenameConversationDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
