import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrick_messenger/screens/chat/image_gallery_layout.dart';

void main() {
  Widget gallery(int count, {ValueChanged<int>? onItemTap}) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: ImageGalleryLayout(
            itemCount: count,
            onItemTap: onItemTap,
            itemBuilder: (context, index) => ColoredBox(
              key: ValueKey('gallery-item-$index'),
              color: Colors.blue,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('three pictures use every supplied preview', (tester) async {
    await tester.pumpWidget(gallery(3));

    expect(find.byKey(const ValueKey('gallery-item-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('gallery-item-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('gallery-item-2')), findsOneWidget);
  });

  testWidgets('five pictures show four previews and remaining count', (
    tester,
  ) async {
    await tester.pumpWidget(gallery(5));

    expect(find.byKey(const ValueKey('gallery-item-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('gallery-item-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('gallery-item-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('gallery-item-3')), findsOneWidget);
    expect(find.byKey(const ValueKey('gallery-item-4')), findsNothing);
    expect(find.text('+1'), findsOneWidget);
  });

  testWidgets('four or more pictures use a hero preview', (tester) async {
    await tester.pumpWidget(gallery(5));

    final hero = tester.getRect(find.byKey(const ValueKey('gallery-item-0')));
    final small = tester.getRect(find.byKey(const ValueKey('gallery-item-1')));

    expect(hero.width, greaterThan(small.width));
    expect(hero.height, greaterThan(small.height));
  });

  testWidgets('tapping overflow reports the fourth picture index', (
    tester,
  ) async {
    int? tappedIndex;

    await tester.pumpWidget(
      gallery(6, onItemTap: (index) => tappedIndex = index),
    );

    await tester.tap(find.text('+2'));
    await tester.pump();

    expect(tappedIndex, 3);
  });
}
