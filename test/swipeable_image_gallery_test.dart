import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrick_messenger/screens/chat/swipeable_image_gallery.dart';

void main() {
  final pixel = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwC'
    'AAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );

  Widget viewer({int initialIndex = 0, bool desktop = false}) {
    return MaterialApp(
      home: SwipeableImageGallery(
        initialIndex: initialIndex,
        desktopControlsOverride: desktop,
        imageLoaders: List.generate(
          3,
          (index) =>
              () async => SwipeableGalleryImage(
                bytes: pixel,
                name: 'picture-$index.png',
                mimeType: 'image/png',
              ),
        ),
      ),
    );
  }

  testWidgets('opens at requested picture', (tester) async {
    await tester.pumpWidget(viewer(initialIndex: 2));
    await tester.pumpAndSettle();

    expect(find.text('3 of 3'), findsOneWidget);
  });

  testWidgets('swipe advances to next picture', (tester) async {
    await tester.pumpWidget(viewer());
    await tester.pumpAndSettle();

    final pageView = find.byKey(const ValueKey('swipeable-gallery-page-view'));
    final bounds = tester.getRect(pageView);

    await tester.flingFrom(
      Offset(bounds.center.dx, bounds.bottom - 80),
      const Offset(-500, 0),
      1200,
    );
    await tester.pumpAndSettle();

    expect(find.text('2 of 3'), findsOneWidget);
  });

  testWidgets('zoom mode uses InteractiveViewer', (tester) async {
    await tester.pumpWidget(viewer());
    await tester.pumpAndSettle();

    expect(find.byType(InteractiveViewer), findsNothing);

    await tester.tap(find.byTooltip('Enable zoom'));
    await tester.pump();

    expect(find.byType(InteractiveViewer), findsOneWidget);
  });

  testWidgets('desktop buttons navigate', (tester) async {
    await tester.pumpWidget(viewer(desktop: true));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Next picture'));
    await tester.pumpAndSettle();

    expect(find.text('2 of 3'), findsOneWidget);
    expect(find.byTooltip('Previous picture'), findsOneWidget);
  });

  testWidgets('arrow key navigates', (tester) async {
    await tester.pumpWidget(viewer());
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();

    expect(find.text('2 of 3'), findsOneWidget);
  });
}
