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
    VoidCallback? onReaction,
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
          onReaction: (_) => onReaction?.call(),
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

    var tapped = '';
    await tester.pumpWidget(
      pump(event, timeline, onReaction: () => tapped = 'tapped'),
    );

    expect(find.text('👍'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);

    await tester.tap(find.text('👍'));
    await tester.pump();
    expect(tapped, 'tapped');
  });

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
