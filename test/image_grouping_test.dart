import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:patrick_messenger/screens/chat/image_grouping.dart';
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
      'image_grouping_test',
      database: database,
      sqfliteFactory: databaseFactoryFfi,
    );
    client = Client('image grouping test', database: matrixDatabase);
    room = Room(id: '!room:matrix.example.test', client: client);
  });

  tearDown(() => client.dispose(closeDatabase: true));

  Event image({
    required String id,
    required DateTime timestamp,
    String sender = '@alice:matrix.example.test',
    String? batchId,
    bool reply = false,
  }) {
    return Event(
      room: room,
      eventId: id,
      senderId: sender,
      originServerTs: timestamp,
      type: EventTypes.Message,
      content: {
        'msgtype': MessageTypes.Image,
        'body': 'photo.jpg',
        'url': 'mxc://matrix.example.test/$id',
        patrickMediaBatchKey: ?batchId,
        if (reply)
          'm.relates_to': {
            'm.in_reply_to': {'event_id': r'$original'},
          },
      },
      status: EventStatus.synced,
    );
  }

  test('matching explicit batch IDs group regardless of upload duration', () {
    final newer = image(
      id: r'$newer',
      timestamp: DateTime(2026, 8, 2, 10, 20),
      batchId: 'batch-1',
    );
    final older = image(
      id: r'$older',
      timestamp: DateTime(2026, 8, 2, 10),
      batchId: 'batch-1',
    );

    expect(shouldGroupImageEvents(newer, older), isTrue);
  });

  test('different explicit batch IDs never group', () {
    final newer = image(
      id: r'$newer',
      timestamp: DateTime(2026, 8, 2, 10, 1),
      batchId: 'batch-2',
    );
    final older = image(
      id: r'$older',
      timestamp: DateTime(2026, 8, 2, 10),
      batchId: 'batch-1',
    );

    expect(shouldGroupImageEvents(newer, older), isFalse);
  });

  test('unmarked adjacent pictures group at exactly two minutes', () {
    final newer = image(id: r'$newer', timestamp: DateTime(2026, 8, 2, 10, 2));
    final older = image(id: r'$older', timestamp: DateTime(2026, 8, 2, 10));

    expect(shouldGroupImageEvents(newer, older), isTrue);
  });

  test('unmarked pictures over two minutes apart do not group', () {
    final newer = image(
      id: r'$newer',
      timestamp: DateTime(2026, 8, 2, 10, 2, 1),
    );
    final older = image(id: r'$older', timestamp: DateTime(2026, 8, 2, 10));

    expect(shouldGroupImageEvents(newer, older), isFalse);
  });

  test('different senders do not group', () {
    final newer = image(id: r'$newer', timestamp: DateTime(2026, 8, 2, 10, 1));
    final older = image(
      id: r'$older',
      timestamp: DateTime(2026, 8, 2, 10),
      sender: '@bob:matrix.example.test',
    );

    expect(shouldGroupImageEvents(newer, older), isFalse);
  });

  test('reply pictures do not group', () {
    final newer = image(
      id: r'$newer',
      timestamp: DateTime(2026, 8, 2, 10, 1),
      reply: true,
    );
    final older = image(id: r'$older', timestamp: DateTime(2026, 8, 2, 10));

    expect(shouldGroupImageEvents(newer, older), isFalse);
  });
}
