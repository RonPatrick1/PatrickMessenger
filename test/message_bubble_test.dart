import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
// TimelineChunk isn't part of the package's public export surface, but it's
// the only way to construct a Timeline with events synchronously and
// without a live server/sync — needed here purely for testing.
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:patrick_messenger/archive/archive_repository.dart';
import 'package:patrick_messenger/receipts/message_receipt_service.dart';
import 'package:patrick_messenger/receipts/read_receipt_preferences.dart';
import 'package:patrick_messenger/screens/chat/message_bubble.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Client client;
  late Room room;
  late ArchiveRoomData archive;
  late MessageReceiptService receiptService;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
    );
    final matrixDatabase = await MatrixSdkDatabase.init(
      'message_bubble_test',
      database: database,
      sqfliteFactory: databaseFactoryFfi,
    );
    client = Client('message bubble test', database: matrixDatabase);
    room = Room(id: '!room:matrix.example.test', client: client);
    archive = ArchiveRoomData(room);
    receiptService = MessageReceiptService(
      client,
      await ReadReceiptPreferenceController.load(),
    );
  });

  tearDown(() => client.dispose(closeDatabase: true));

  Event message({
    required String eventId,
    String body = 'Hello',
    String senderId = '@alice:matrix.example.test',
  }) => Event(
    room: room,
    eventId: eventId,
    senderId: senderId,
    originServerTs: DateTime(2026, 7, 29, 9, 0),
    type: EventTypes.Message,
    content: {'msgtype': MessageTypes.Text, 'body': body},
    status: EventStatus.synced,
  );

  Event reaction({
    required String eventId,
    required String relatesToEventId,
    required String emoji,
    String senderId = '@alice:matrix.example.test',
  }) => Event(
    room: room,
    eventId: eventId,
    senderId: senderId,
    originServerTs: DateTime(2026, 7, 29, 9, 1),
    type: EventTypes.Reaction,
    content: {
      'm.relates_to': {
        'rel_type': RelationshipTypes.reaction,
        'event_id': relatesToEventId,
        'key': emoji,
      },
    },
    status: EventStatus.synced,
  );

  Widget pump(
    Event event,
    Timeline timeline, {
    bool selectionMode = false,
    ValueChanged<String>? onReaction,
    VoidCallback? onReply,
    VoidCallback? onOpenActions,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: MessageBubble(
          event: event,
          timeline: timeline,
          mine: false,
          selectionMode: selectionMode,
          selected: false,
          pinned: false,
          actionsEnabled: true,
          liamUserId: '@liam:matrix.example.test',
          onOpenActions: onOpenActions ?? () {},
          onSelectionTap: () {},
          onReaction: onReaction ?? (_) {},
          onReply: onReply ?? () {},
          receiptService: receiptService,
          archive: archive,
        ),
      ),
    );
  }

  testWidgets('renders a reaction badge and toggles it on tap', (
    tester,
  ) async {
    final event = message(eventId: r'$message');
    final timeline = Timeline(
      room: room,
      chunk: TimelineChunk(events: [event]),
    );
    timeline.addAggregatedEvent(
      reaction(
        eventId: r'$reaction',
        relatesToEventId: event.eventId,
        emoji: '👍',
      ),
    );

    String? tapped;
    await tester.pumpWidget(
      pump(event, timeline, onReaction: (emoji) => tapped = emoji),
    );

    expect(find.text('👍'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);

    await tester.tap(find.text('👍'));
    await tester.pump();
    expect(tapped, '👍');
  });

  testWidgets(
    'multiple reaction types overlap as a cluster and stay individually '
    'tappable',
    (tester) async {
      final event = message(eventId: r'$message');
      final timeline = Timeline(
        room: room,
        chunk: TimelineChunk(events: [event]),
      );
      timeline.addAggregatedEvent(
        reaction(eventId: r'$r1', relatesToEventId: event.eventId, emoji: '👍'),
      );
      timeline.addAggregatedEvent(
        reaction(
          eventId: r'$r2',
          relatesToEventId: event.eventId,
          emoji: '❤️',
          senderId: '@bob:matrix.example.test',
        ),
      );

      String? tapped;
      await tester.pumpWidget(
        pump(event, timeline, onReaction: (emoji) => tapped = emoji),
      );

      // No per-emoji counts in the overlapped view, just one combined total.
      expect(find.text('1'), findsNothing);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('👍'), findsOneWidget);
      expect(find.text('❤️'), findsOneWidget);

      await tester.tap(find.text('❤️'));
      await tester.pump();
      expect(tapped, '❤️');
    },
  );

  testWidgets(
    'tapping the cluster total explodes it into a popup with every '
    'reaction individually clickable',
    (tester) async {
      final event = message(eventId: r'$message');
      final timeline = Timeline(
        room: room,
        chunk: TimelineChunk(events: [event]),
      );
      timeline.addAggregatedEvent(
        reaction(eventId: r'$r1', relatesToEventId: event.eventId, emoji: '👍'),
      );
      timeline.addAggregatedEvent(
        reaction(
          eventId: r'$r2',
          relatesToEventId: event.eventId,
          emoji: '❤️',
          senderId: '@bob:matrix.example.test',
        ),
      );
      timeline.addAggregatedEvent(
        reaction(
          eventId: r'$r3',
          relatesToEventId: event.eventId,
          emoji: '😂',
          senderId: '@carol:matrix.example.test',
        ),
      );

      String? tapped;
      await tester.pumpWidget(
        pump(event, timeline, onReaction: (emoji) => tapped = emoji),
      );

      // Tap the total count (not a specific circle) to explode the cluster.
      await tester.tap(find.text('3'));
      await tester.pumpAndSettle();

      // Every reaction now has its own fully visible, separately tappable
      // pill in the popup (in addition to the still-present collapsed
      // circles underneath).
      expect(find.text('👍'), findsNWidgets(2));
      expect(find.text('❤️'), findsNWidgets(2));
      expect(find.text('😂'), findsNWidgets(2));

      await tester.tap(find.text('😂').last);
      await tester.pumpAndSettle();

      expect(tapped, '😂');
      // The popup closes itself after a selection (showMenu's default
      // behavior), leaving only the collapsed cluster's own circle.
      expect(find.text('😂'), findsOneWidget);
    },
  );

  testWidgets('hover reveals the quick-action toolbar, exit hides it', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;

    final event = message(eventId: r'$message');
    final timeline = Timeline(
      room: room,
      chunk: TimelineChunk(events: [event]),
    );
    await tester.pumpWidget(pump(event, timeline));

    expect(find.byTooltip('Reply'), findsNothing);

    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await gesture.addPointer(
      location: tester.getCenter(find.byType(MessageBubble)),
    );
    await tester.pump();
    expect(find.byTooltip('Reply'), findsOneWidget);

    await gesture.removePointer();
    await tester.pump();
    expect(find.byTooltip('Reply'), findsNothing);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'moving onto the toolbar keeps it visible and clickable '
    '(regression: toolbar used to overflow its hit-testable bounds)',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;

      final event = message(eventId: r'$message');
      final timeline = Timeline(
        room: room,
        chunk: TimelineChunk(events: [event]),
      );
      var replied = false;
      await tester.pumpWidget(
        pump(event, timeline, onReply: () => replied = true),
      );

      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await gesture.addPointer(
        location: tester.getCenter(find.byType(MessageBubble)),
      );
      await tester.pump();
      expect(find.byTooltip('Reply'), findsOneWidget);

      // Move from the bubble onto the toolbar's own rendered position, the
      // same motion a real user makes to reach it. This must NOT trigger
      // onExit along the way, and the toolbar must still be there once the
      // pointer actually arrives.
      await gesture.moveTo(tester.getCenter(find.byTooltip('Reply')));
      await tester.pump();
      expect(find.byTooltip('Reply'), findsOneWidget);

      await tester.tap(find.byTooltip('Reply'));
      await tester.pump();
      expect(replied, isTrue);

      await gesture.removePointer();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('hover toolbar stays hidden in selection mode', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;

    final event = message(eventId: r'$message');
    final timeline = Timeline(
      room: room,
      chunk: TimelineChunk(events: [event]),
    );
    await tester.pumpWidget(pump(event, timeline, selectionMode: true));

    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await gesture.addPointer(
      location: tester.getCenter(find.byType(MessageBubble)),
    );
    await tester.pump();
    expect(find.byTooltip('Reply'), findsNothing);

    await gesture.removePointer();
    debugDefaultTargetPlatformOverride = null;
  });
}
