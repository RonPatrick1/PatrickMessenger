import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:patrick_messenger/matrix/timeline_event_merge.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Client client;
  late Room room;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    final database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
    );
    final matrixDatabase = await MatrixSdkDatabase.init(
      'timeline_merge_test',
      database: database,
      sqfliteFactory: databaseFactoryFfi,
    );
    client = Client('timeline merge test', database: matrixDatabase);
    room = Room(id: '!room:matrix.example.test', client: client);
  });

  tearDown(() => client.dispose(closeDatabase: true));

  Event message({
    required String eventId,
    required EventStatus status,
    String? transactionId,
    String body = 'Yo',
    DateTime? timestamp,
  }) => Event(
    room: room,
    eventId: eventId,
    senderId: '@alice:matrix.example.test',
    originServerTs: timestamp ?? DateTime(2026, 7, 28, 9, 51),
    type: EventTypes.Message,
    content: {'msgtype': MessageTypes.Text, 'body': body},
    unsigned: transactionId == null ? null : {'transaction_id': transactionId},
    status: status,
  );

  test('replaces a pending local echo with its synced event', () {
    final pending = message(
      eventId: 'transaction-1',
      transactionId: 'transaction-1',
      status: EventStatus.sending,
    );
    final synced = message(
      eventId: r'$server-event',
      transactionId: 'transaction-1',
      status: EventStatus.synced,
    );

    final merged = mergeMatrixTimelineEvents(
      timelineEvents: [pending],
      liveEvents: [pending, synced],
    );

    expect(merged, hasLength(1));
    expect(merged.single.eventId, r'$server-event');
    expect(merged.single.status, EventStatus.synced);
  });

  test('recognizes a local echo when sync omits its transaction ID', () {
    final pending = message(eventId: 'transaction-2', status: EventStatus.sent);
    final synced = message(
      eventId: r'$server-event-2',
      status: EventStatus.synced,
      timestamp: DateTime(2026, 7, 28, 9, 51, 2),
    );

    final merged = mergeMatrixTimelineEvents(
      timelineEvents: [pending],
      liveEvents: [synced],
    );

    expect(merged, hasLength(1));
    expect(merged.single.eventId, r'$server-event-2');
  });

  test('keeps two genuinely synced identical messages', () {
    final first = message(eventId: r'$first', status: EventStatus.synced);
    final second = message(eventId: r'$second', status: EventStatus.synced);

    final merged = mergeMatrixTimelineEvents(
      timelineEvents: [first],
      liveEvents: [second],
    );

    expect(merged.map((event) => event.eventId), [r'$first', r'$second']);
  });
}
