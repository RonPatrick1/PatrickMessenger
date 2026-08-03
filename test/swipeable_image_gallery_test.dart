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

  testWidgets('toolbar controls never overlap the picture viewport', (
    tester,
  ) async {
    await tester.pumpWidget(viewer());
    await tester.pumpAndSettle();

    final pageView = find.byKey(const ValueKey('swipeable-gallery-page-view'));
    final pageBounds = tester.getRect(pageView);

    for (final control in [
      find.byTooltip('Close'),
      find.text('1 of 3'),
      find.byTooltip('Enable zoom'),
      find.byTooltip('Save picture'),
    ]) {
      expect(tester.getRect(control).bottom, lessThanOrEqualTo(pageBounds.top));
    }
  });

  testWidgets('desktop navigation controls stay in the toolbar', (
    tester,
  ) async {
    await tester.pumpWidget(viewer(initialIndex: 1, desktop: true));
    await tester.pumpAndSettle();

    final pageBounds = tester.getRect(
      find.byKey(const ValueKey('swipeable-gallery-page-view')),
    );
    expect(
      tester.getRect(find.byTooltip('Previous picture')).bottom,
      lessThanOrEqualTo(pageBounds.top),
    );
    expect(
      tester.getRect(find.byTooltip('Next picture')).bottom,
      lessThanOrEqualTo(pageBounds.top),
    );
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
