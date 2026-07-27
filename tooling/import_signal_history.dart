import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vodozemac/vodozemac.dart' as vodozemac;

import 'package:patrick_messenger/archive/archive_contract.dart';
import 'package:patrick_messenger/archive/archive_models.dart';
import 'package:patrick_messenger/archive/signal_export_parser.dart';

const _defaultHomeserver = 'https://patrick-lamphier.com';
const _defaultRoomId = '!clyhRDMlMkkRKwlyca:matrix.patrick-lamphier.com';
const _defaultRon = '@ron_patrick:matrix.patrick-lamphier.com';
const _defaultElizabeth = '@elizabeth_patrick:matrix.patrick-lamphier.com';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('source', abbr: 's', help: 'Signal export directory.')
    ..addOption('room-id', defaultsTo: _defaultRoomId)
    ..addOption('homeserver', defaultsTo: _defaultHomeserver)
    ..addOption('account', defaultsTo: _defaultRon)
    ..addOption('contact', defaultsTo: _defaultElizabeth)
    ..addOption('contact-name', defaultsTo: 'Elizabeth Patrick')
    ..addFlag(
      'scan-only',
      negatable: false,
      help: 'Validate and print counts without uploading.',
    )
    ..addFlag('skip-ocr', negatable: false, help: 'Skip local Tesseract OCR.')
    ..addFlag('yes', abbr: 'y', negatable: false)
    ..addFlag('help', abbr: 'h', negatable: false);
  final options = parser.parse(arguments);
  if (options['help'] as bool || options['source'] == null) {
    stdout.writeln(
      'Usage: dart run tooling/import_signal_history.dart '
      '--source /path/to/signal-export [--scan-only] [--yes]\n',
    );
    stdout.writeln(parser.usage);
    exitCode = options['help'] as bool ? 0 : 64;
    return;
  }

  final source = Directory(options['source'] as String);
  final signalParser = SignalExportParser(
    source: source,
    accountMatrixId: options['account'] as String,
    contactMatrixId: options['contact'] as String,
    contactNameHint: options['contact-name'] as String,
    recognizeText: options['skip-ocr'] as bool ? null : _tesseract,
  );
  final scan = await signalParser.scan();
  _printScan(scan);
  if (options['scan-only'] as bool) {
    final validated = await signalParser.parse(onProgress: stdout.writeln);
    stdout.writeln(
      'Media: ${validated.availableMedia} available, '
      '${validated.missingMedia} missing, '
      '${validated.unreferencedMedia} unreferenced.',
    );
    return;
  }

  if (!(options['yes'] as bool)) {
    stdout.write('Import this history into The Patricks? [y/N] ');
    final answer = stdin.readLineSync()?.trim().toLowerCase();
    if (answer != 'y' && answer != 'yes') return;
  }

  // Validate native encryption before spending time parsing a large export.
  await _ensureVodozemacInitialized();
  final result = await signalParser.parse(onProgress: stdout.writeln);
  stdout.writeln(
    'Media: ${result.availableMedia} available, '
    '${result.missingMedia} missing, '
    '${result.unreferencedMedia} unreferenced.',
  );
  await _SignalArchiveUploader(
    result: result,
    homeserver: Uri.parse(options['homeserver'] as String),
    roomId: options['room-id'] as String,
    accountMatrixId: options['account'] as String,
  ).run();
}

void _printScan(SignalExportScan scan) {
  stdout.writeln('Signal account: ${scan.accountName}');
  stdout.writeln('Conversation: ${scan.contactName}');
  stdout.writeln('Messages: ${scan.messageCount}');
  stdout.writeln('From: ${scan.firstTimestamp.toLocal()}');
  stdout.writeln('Through: ${scan.lastTimestamp.toLocal()}');
}

Future<String?> _tesseract(File file, String mimeType) async {
  if (!mimeType.startsWith('image/')) return null;
  try {
    final result = await Process.run('tesseract', [
      file.path,
      'stdout',
      '--psm',
      '6',
      '-l',
      'eng',
    ]);
    if (result.exitCode != 0) return null;
    final text = result.stdout.toString().trim();
    return text.isEmpty ? null : text;
  } on ProcessException {
    return null;
  }
}

class _SignalArchiveUploader {
  final SignalParseResult result;
  final Uri homeserver;
  final String roomId;
  final String accountMatrixId;

  late final String importId = _createImportId();
  late final Directory workingDirectory;
  late final File checkpointFile;
  late final Map<String, dynamic> checkpoint;

  _SignalArchiveUploader({
    required this.result,
    required this.homeserver,
    required this.roomId,
    required this.accountMatrixId,
  });

  Future<void> run() async {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw StateError('HOME is required for the resumable importer store.');
    }
    workingDirectory = Directory(
      path.join(home, '.patrick-messenger-import', importId),
    );
    await workingDirectory.create(recursive: true);
    if (!Platform.isWindows) {
      await Process.run('chmod', ['700', workingDirectory.path]);
    }
    checkpointFile = File(path.join(workingDirectory.path, 'checkpoint.json'));
    checkpoint = await checkpointFile.exists()
        ? Map<String, dynamic>.from(
            jsonDecode(await checkpointFile.readAsString()) as Map,
          )
        : <String, dynamic>{
            'schema_version': archiveSchemaVersion,
            'import_id': importId,
            'media': <String, dynamic>{},
            'chunks': <dynamic>[],
          };

    final client = await _connect();
    try {
      final room = client.getRoomById(roomId);
      if (room == null || room.membership != Membership.join) {
        throw StateError('The importer account is not joined to $roomId.');
      }
      await room.postLoad();
      if (!room.encrypted) {
        throw StateError('Refusing to import into an unencrypted room.');
      }
      final participants = room
          .getParticipants(const [Membership.join])
          .map((user) => user.id)
          .toSet();
      if (!participants.contains(result.messages.first.authorMatrixId) ||
          !participants.contains(
            result.messages
                .firstWhere(
                  (message) =>
                      message.authorMatrixId !=
                      result.messages.first.authorMatrixId,
                )
                .authorMatrixId,
          )) {
        throw StateError(
          'The target room does not contain both mapped Signal accounts.',
        );
      }

      final mediaRefs = await _uploadMedia(client);
      final populated = result.messages
          .map((message) {
            return ArchiveMessage(
              id: message.id,
              authorMatrixId: message.authorMatrixId,
              authorName: message.authorName,
              timestamp: message.timestamp,
              kind: message.kind,
              body: message.body,
              edited: message.edited,
              deleted: message.deleted,
              replyToId: message.replyToId,
              deliveryState: message.deliveryState,
              reactions: message.reactions,
              revisions: message.revisions,
              attachments: message.attachments
                  .map(
                    (attachment) =>
                        attachment.copyWith(file: mediaRefs[attachment.id]),
                  )
                  .toList(growable: false),
            );
          })
          .toList(growable: false);
      final chunks = await _uploadChunks(client, populated);
      final manifest = ArchiveManifest(
        schemaVersion: archiveSchemaVersion,
        importId: importId,
        roomId: roomId,
        source: 'Signal Desktop ${result.scan.accountName}',
        importedAt: DateTime.now().toUtc(),
        messageCount: populated.length,
        firstTimestamp: populated.first.timestamp,
        lastTimestamp: populated.last.timestamp,
        chunks: chunks,
      );
      final manifestRef = await _uploadEncrypted(
        client,
        Uint8List.fromList(manifest.encode()),
        'signal-archive-$importId.json',
        'application/json',
      );
      final rootEvent = room.getState(EventTypes.RoomCreate);
      final rootEventId = rootEvent is Event ? rootEvent.eventId : '';
      final manifestEventId = await room.sendEvent(
        {
          'schema_version': archiveSchemaVersion,
          'import_id': importId,
          'file': manifestRef.toJson(),
          'body': 'Encrypted Signal history archive',
          if (rootEventId.isNotEmpty)
            'm.relates_to': controlRelation(rootEventId),
        },
        type: archiveManifestEventType,
        displayPendingEvent: false,
      );
      if (manifestEventId == null) {
        throw StateError('The encrypted archive manifest was not accepted.');
      }
      await client
          .setRoomStateWithKey(roomId, archivePointerStateType, importId, {
            'schema_version': archiveSchemaVersion,
            'import_id': importId,
            'manifest_event_id': manifestEventId,
            'message_count': populated.length,
            'first_timestamp': populated.first.timestamp.millisecondsSinceEpoch,
            'last_timestamp': populated.last.timestamp.millisecondsSinceEpoch,
          });
      checkpoint['manifest_event_id'] = manifestEventId;
      await _saveCheckpoint();
      stdout.writeln(
        'Import complete: ${populated.length} messages are now available '
        'to updated Patrick Messenger clients.',
      );
    } finally {
      await client.dispose();
    }
  }

  Future<Client> _connect() async {
    await _ensureVodozemacInitialized();
    sqfliteFfiInit();
    final databasePath = path.join(workingDirectory.path, 'matrix.sqlite');
    final database = await databaseFactoryFfi.openDatabase(databasePath);
    final matrixDatabase = await MatrixSdkDatabase.init(
      'patrick_signal_importer_$importId',
      database: database,
      sqfliteFactory: databaseFactoryFfi,
      maxFileSize: 0,
    );
    final client = Client(
      'Patrick Messenger Signal Importer',
      database: matrixDatabase,
      receiptsPublicByDefault: false,
      requestHistoryOnLimitedTimeline: false,
    );
    client.backgroundSync = false;
    await client.init(newHomeserver: homeserver);
    if (!client.isLogged()) {
      final password = _readPassword('Matrix password for $accountMatrixId: ');
      await client.login(
        AuthenticationTypes.password,
        identifier: AuthenticationUserIdentifier(user: accountMatrixId),
        password: password,
        initialDeviceDisplayName: 'Signal history importer',
      );
    }
    await client.oneShotSync(timeout: const Duration(seconds: 1));
    return client;
  }

  Future<Map<String, ArchiveEncryptedFileRef>> _uploadMedia(
    Client client,
  ) async {
    final saved = Map<String, dynamic>.from(
      checkpoint['media'] as Map? ?? const {},
    );
    final resultRefs = <String, ArchiveEncryptedFileRef>{
      for (final entry in saved.entries)
        entry.key: ArchiveEncryptedFileRef.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        ),
    };
    final usedIds = result.messages
        .expand((message) => message.attachments)
        .map((attachment) => attachment.id)
        .toSet();
    var completed = resultRefs.length;
    for (final id in usedIds) {
      if (resultRefs.containsKey(id)) continue;
      final file = result.mediaFiles[id];
      if (file == null) continue;
      final attachment = result.messages
          .expand((message) => message.attachments)
          .firstWhere((attachment) => attachment.id == id);
      final ref = await _uploadEncrypted(
        client,
        await file.readAsBytes(),
        attachment.name,
        attachment.mimeType,
      );
      resultRefs[id] = ref;
      saved[id] = ref.toJson();
      checkpoint['media'] = saved;
      await _saveCheckpoint();
      completed++;
      stdout.writeln('Uploaded media $completed of ${usedIds.length}');
    }
    return resultRefs;
  }

  Future<List<ArchiveEncryptedFileRef>> _uploadChunks(
    Client client,
    List<ArchiveMessage> messages,
  ) async {
    final existing = (checkpoint['chunks'] as List? ?? const [])
        .map(
          (item) => ArchiveEncryptedFileRef.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList();
    const chunkSize = 500;
    final chunkCount = (messages.length / chunkSize).ceil();
    for (var index = existing.length; index < chunkCount; index++) {
      final start = index * chunkSize;
      final end = (start + chunkSize).clamp(0, messages.length);
      final jsonBytes = utf8.encode(
        jsonEncode(
          messages
              .sublist(start, end)
              .map((message) => message.toJson())
              .toList(),
        ),
      );
      final compressed = Uint8List.fromList(GZipEncoder().encode(jsonBytes));
      final ref = await _uploadEncrypted(
        client,
        compressed,
        'signal-$importId-${index.toString().padLeft(3, '0')}.json.gz',
        'application/gzip',
      );
      existing.add(ref);
      checkpoint['chunks'] = existing.map((chunk) => chunk.toJson()).toList();
      await _saveCheckpoint();
      stdout.writeln('Uploaded history chunk ${index + 1} of $chunkCount');
    }
    return existing;
  }

  Future<ArchiveEncryptedFileRef> _uploadEncrypted(
    Client client,
    Uint8List bytes,
    String name,
    String mimeType,
  ) async {
    final encrypted = await MatrixFile(
      bytes: bytes,
      name: name,
      mimeType: mimeType,
    ).encrypt();
    final url = await client.uploadContent(
      encrypted.data,
      filename: '$name.encrypted',
      contentType: 'application/octet-stream',
    );
    return ArchiveEncryptedFileRef(
      url: url.toString(),
      key: encrypted.k,
      iv: encrypted.iv,
      sha256: encrypted.sha256,
      name: name,
      mimeType: mimeType,
      size: bytes.length,
    );
  }

  Future<void> _saveCheckpoint() async {
    await checkpointFile.writeAsString(jsonEncode(checkpoint), flush: true);
    if (!Platform.isWindows) {
      await Process.run('chmod', ['600', checkpointFile.path]);
    }
  }

  String _createImportId() {
    final source = [
      result.scan.accountName,
      result.scan.contactName,
      result.scan.chatId,
      result.scan.firstTimestamp.millisecondsSinceEpoch,
      result.scan.lastTimestamp.millisecondsSinceEpoch,
      result.scan.messageCount,
    ].join('|');
    return sha256.convert(utf8.encode(source)).toString().substring(0, 24);
  }
}

Future<void> _ensureVodozemacInitialized() async {
  if (vodozemac.isInitialized()) return;
  final libraryDirectory = _findVodozemacLibraryDirectory();
  await vodozemac.init(
    // flutter_rust_bridge resolves a library filename relative to this URI.
    // The trailing separator is required or the final `lib` directory is
    // treated as a filename and replaced during URI resolution.
    libraryPath: '${libraryDirectory.path}${path.separator}',
  );
}

Directory _findVodozemacLibraryDirectory() {
  final candidates = [
    Directory('build/linux/x64/release/bundle/lib'),
    Directory('build/linux/x64/debug/bundle/lib'),
  ];
  for (final candidate in candidates) {
    if (File(
      path.join(candidate.path, 'libvodozemac_bindings_dart.so'),
    ).existsSync()) {
      return candidate.absolute;
    }
  }
  throw StateError(
    'The importer needs the Linux Vodozemac library. Build Patrick Messenger '
    'for Linux once, then run this command again.',
  );
}

String _readPassword(String prompt) {
  stdout.write(prompt);
  final echoWasEnabled = stdin.echoMode;
  try {
    stdin.echoMode = false;
    return stdin.readLineSync() ?? '';
  } finally {
    stdin.echoMode = echoWasEnabled;
    stdout.writeln();
  }
}
