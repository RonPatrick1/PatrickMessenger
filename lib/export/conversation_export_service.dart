import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as path;

import '../archive/archive_models.dart';
import '../archive/archive_repository.dart';
import '../history/timeline_key_recovery.dart';
import '../matrix/display_names.dart';

enum ConversationExportPhase { loadingHistory, exporting, finishing }

class ConversationExportProgress {
  final ConversationExportPhase phase;
  final int completed;
  final int total;
  final String message;

  const ConversationExportProgress({
    required this.phase,
    required this.completed,
    required this.total,
    required this.message,
  });

  double? get fraction => total <= 0 ? null : completed / total;
}

class ConversationExportResult {
  final String path;
  final int messageCount;
  final int mediaCount;
  final int missingMediaCount;
  final int undecryptableCount;

  const ConversationExportResult({
    required this.path,
    required this.messageCount,
    required this.mediaCount,
    required this.missingMediaCount,
    required this.undecryptableCount,
  });
}

class ConversationExportService {
  static const schemaVersion = 1;

  static String suggestedFileName(Room room) {
    final roomName = _safeFileComponent(readableMatrixRoomName(room));
    final now = DateTime.now();
    final date =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    return '${roomName.isEmpty ? 'conversation' : roomName}-$date.zip';
  }

  Future<ConversationExportResult> export({
    required Room room,
    required ArchiveRoomData importedArchive,
    required String destinationPath,
    void Function(ConversationExportProgress progress)? onProgress,
  }) async {
    onProgress?.call(
      const ConversationExportProgress(
        phase: ConversationExportPhase.loadingHistory,
        completed: 0,
        total: 0,
        message: 'Loading the complete encrypted conversation…',
      ),
    );

    await importedArchive.load();
    final timeline = await room.getTimeline();
    final encoder = ZipFileEncoder();
    var encoderOpen = false;
    try {
      var loadedPages = 0;
      while (timeline.canRequestHistory) {
        await timeline.requestHistory(historyCount: 250);
        loadedPages++;
        onProgress?.call(
          ConversationExportProgress(
            phase: ConversationExportPhase.loadingHistory,
            completed: loadedPages,
            total: 0,
            message: 'Loading older messages…',
          ),
        );
      }
      onProgress?.call(
        const ConversationExportProgress(
          phase: ConversationExportPhase.loadingHistory,
          completed: 0,
          total: 0,
          message: 'Restoring available encryption keys…',
        ),
      );
      await recoverTimelineKeys(timeline);

      final items =
          <_ExportItem>[
            ...timeline.events
                .where(_isExportableMatrixEvent)
                .map(_ExportItem.matrix),
            ...importedArchive.messages.map(_ExportItem.imported),
          ]..sort((a, b) {
            final byTime = a.timestamp.compareTo(b.timestamp);
            return byTime != 0 ? byTime : a.id.compareTo(b.id);
          });

      final output = File(destinationPath);
      await output.parent.create(recursive: true);
      if (await output.exists()) await output.delete();
      encoder.create(destinationPath);
      encoderOpen = true;

      final jsonLines = StringBuffer();
      final readable = StringBuffer()
        ..writeln('Patrick Messenger conversation export')
        ..writeln('Conversation: ${readableMatrixRoomName(room)}')
        ..writeln('Room ID: ${room.id}')
        ..writeln('Exported: ${DateTime.now().toUtc().toIso8601String()}')
        ..writeln()
        ..writeln(
          'SECURITY WARNING: This archive contains decrypted messages and '
          'media. Anyone who obtains it can read the exported conversation.',
        )
        ..writeln();
      final usedMediaPaths = <String>{};
      var mediaCount = 0;
      var missingMediaCount = 0;
      var undecryptableCount = 0;

      for (var index = 0; index < items.length; index++) {
        final item = items[index];
        if (index == 0 || index % 50 == 0 || index == items.length - 1) {
          onProgress?.call(
            ConversationExportProgress(
              phase: ConversationExportPhase.exporting,
              completed: index + 1,
              total: items.length,
              message: 'Exporting message ${index + 1} of ${items.length}…',
            ),
          );
        }

        final record = item.event != null
            ? await _matrixRecord(
                item.event!,
                timeline,
                encoder,
                usedMediaPaths,
              )
            : await _importedRecord(
                item.importedMessage!,
                importedArchive,
                encoder,
                usedMediaPaths,
              );
        mediaCount += record.mediaCount;
        missingMediaCount += record.missingMediaCount;
        if (record.undecryptable) undecryptableCount++;
        jsonLines.writeln(jsonEncode(record.json));
        _writeReadableRecord(readable, record.json);
      }

      final exportedAt = DateTime.now().toUtc();
      final manifest = <String, Object?>{
        'schema_version': schemaVersion,
        'format': 'patrick-messenger-conversation-export',
        'room_id': room.id,
        'room_name': readableMatrixRoomName(room),
        'exported_at': exportedAt.toIso8601String(),
        'message_count': items.length,
        'media_count': mediaCount,
        'missing_media_count': missingMediaCount,
        'undecryptable_message_count': undecryptableCount,
        'messages_file': 'conversation.jsonl',
        'readable_file': 'conversation.txt',
        'media_directory': 'media/',
      };
      encoder
        ..addArchiveFile(
          ArchiveFile.string(
            'README.txt',
            'Patrick Messenger conversation export\n\n'
                'conversation.txt is a human-readable transcript.\n'
                'conversation.jsonl contains one JSON record per message.\n'
                'media/ contains decrypted attachments that were available '
                'to this device.\n\n'
                'SECURITY WARNING: This ZIP is not end-to-end encrypted. '
                'Store it somewhere private and protected.\n',
          ),
        )
        ..addArchiveFile(
          ArchiveFile.string(
            'manifest.json',
            const JsonEncoder.withIndent('  ').convert(manifest),
          ),
        )
        ..addArchiveFile(
          ArchiveFile.string('conversation.jsonl', jsonLines.toString()),
        )
        ..addArchiveFile(
          ArchiveFile.string('conversation.txt', readable.toString()),
        );

      onProgress?.call(
        ConversationExportProgress(
          phase: ConversationExportPhase.finishing,
          completed: items.length,
          total: items.length,
          message: 'Finishing the ZIP archive…',
        ),
      );
      await encoder.close();
      encoderOpen = false;
      return ConversationExportResult(
        path: destinationPath,
        messageCount: items.length,
        mediaCount: mediaCount,
        missingMediaCount: missingMediaCount,
        undecryptableCount: undecryptableCount,
      );
    } catch (_) {
      if (encoderOpen) {
        try {
          await encoder.close();
        } catch (_) {
          // Preserve the original export failure.
        }
      }
      final partial = File(destinationPath);
      if (await partial.exists()) await partial.delete();
      rethrow;
    } finally {
      timeline.cancelSubscriptions();
    }
  }

  static bool _isExportableMatrixEvent(Event event) {
    if (event.relationshipType == RelationshipTypes.edit) return false;
    return event.type == EventTypes.Message ||
        event.type == EventTypes.Sticker ||
        event.type == EventTypes.Encrypted;
  }

  Future<_ExportRecord> _matrixRecord(
    Event event,
    Timeline timeline,
    ZipFileEncoder encoder,
    Set<String> usedMediaPaths,
  ) async {
    final undecryptable = isUndecryptableEvent(event);
    final display = undecryptable ? event : event.getDisplayEvent(timeline);
    final media = <Map<String, Object?>>[];
    var mediaCount = 0;
    var missingMediaCount = 0;
    if (!undecryptable && _hasAttachment(display)) {
      try {
        final attachment = await display.downloadAndDecryptAttachment();
        final archivePath = _uniqueMediaPath(
          usedMediaPaths,
          event.originServerTs,
          event.eventId,
          attachment.name,
        );
        encoder.addArchiveFile(
          ArchiveFile.bytes(archivePath, attachment.bytes),
        );
        mediaCount++;
        media.add({
          'name': attachment.name,
          'mime_type': attachment.mimeType,
          'size': attachment.bytes.length,
          'sha256': sha256.convert(attachment.bytes).toString(),
          'archive_path': archivePath,
          'missing': false,
        });
      } catch (_) {
        missingMediaCount++;
        media.add({
          'name': display.content['filename']?.toString() ?? display.body,
          'mime_type': display.content['info'] is Map
              ? (display.content['info'] as Map)['mimetype']?.toString()
              : null,
          'missing': true,
          'error': 'Attachment could not be downloaded or decrypted.',
        });
      }
    }

    final reactions = <Map<String, Object?>>[];
    if (!undecryptable) {
      for (final reaction in event.aggregatedEvents(
        timeline,
        RelationshipTypes.reaction,
      )) {
        if (reaction.redacted) continue;
        final relation = reaction.content['m.relates_to'];
        final emoji = relation is Map ? relation['key']?.toString() : null;
        if (emoji == null || emoji.isEmpty) continue;
        reactions.add({
          'emoji': emoji,
          'author_id': reaction.senderId,
          'author_name': readableMatrixUserName(
            reaction.senderFromMemoryOrFallback,
          ),
          'timestamp': reaction.originServerTs.toUtc().toIso8601String(),
        });
      }
    }

    return _ExportRecord(
      json: {
        'source': 'matrix',
        'id': event.eventId,
        'sender_id': event.senderId,
        'sender_name': readableMatrixUserName(event.senderFromMemoryOrFallback),
        'timestamp': event.originServerTs.toUtc().toIso8601String(),
        'timestamp_ms': event.originServerTs.millisecondsSinceEpoch,
        'kind': undecryptable ? 'undecryptable' : display.messageType,
        'body': undecryptable
            ? '[This device could not decrypt this message]'
            : display.redacted
            ? 'Message deleted'
            : display.calcUnlocalizedBody(
                hideReply: true,
                hideEdit: true,
                plaintextBody: true,
              ),
        'edited':
            !undecryptable &&
            event.hasAggregatedEvents(timeline, RelationshipTypes.edit),
        'deleted': display.redacted,
        'reply_to_id': ?_matrixReplyTarget(event),
        'reactions': reactions,
        'media': media,
      },
      mediaCount: mediaCount,
      missingMediaCount: missingMediaCount,
      undecryptable: undecryptable,
    );
  }

  Future<_ExportRecord> _importedRecord(
    ArchiveMessage message,
    ArchiveRoomData importedArchive,
    ZipFileEncoder encoder,
    Set<String> usedMediaPaths,
  ) async {
    final media = <Map<String, Object?>>[];
    var mediaCount = 0;
    var missingMediaCount = 0;
    for (final attachment in message.attachments) {
      if (attachment.missing) {
        missingMediaCount++;
        media.add({
          'id': attachment.id,
          'name': attachment.name,
          'mime_type': attachment.mimeType,
          'size': attachment.size,
          'missing': true,
        });
        continue;
      }
      try {
        final bytes = await importedArchive.download(attachment.file!);
        final archivePath = _uniqueMediaPath(
          usedMediaPaths,
          message.timestamp,
          message.id,
          attachment.name,
        );
        encoder.addArchiveFile(ArchiveFile.bytes(archivePath, bytes));
        mediaCount++;
        media.add({
          'id': attachment.id,
          'name': attachment.name,
          'mime_type': attachment.mimeType,
          'size': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
          'archive_path': archivePath,
          'caption': attachment.caption,
          'ocr_text': attachment.ocrText,
          'missing': false,
        });
      } catch (_) {
        missingMediaCount++;
        media.add({
          'id': attachment.id,
          'name': attachment.name,
          'mime_type': attachment.mimeType,
          'size': attachment.size,
          'missing': true,
          'error': 'Attachment could not be downloaded or decrypted.',
        });
      }
    }

    return _ExportRecord(
      json: {
        'source': 'imported_signal',
        'id': message.id,
        'sender_id': message.authorMatrixId,
        'sender_name': message.authorName,
        'timestamp': message.timestamp.toUtc().toIso8601String(),
        'timestamp_ms': message.timestamp.millisecondsSinceEpoch,
        'kind': message.kind.name,
        'body': message.body,
        'edited': message.edited,
        'deleted': message.deleted,
        'reply_to_id': ?message.replyToId,
        'delivery_state': ?message.deliveryState?.name,
        'revisions': message.revisions,
        'reactions': message.reactions
            .map(
              (reaction) => {
                'emoji': reaction.emoji,
                'author_id': reaction.authorMatrixId,
                'author_name': reaction.authorName,
                'timestamp': reaction.timestamp.toUtc().toIso8601String(),
              },
            )
            .toList(growable: false),
        'media': media,
      },
      mediaCount: mediaCount,
      missingMediaCount: missingMediaCount,
      undecryptable: false,
    );
  }

  static bool _hasAttachment(Event event) => {
    MessageTypes.Image,
    MessageTypes.Sticker,
    MessageTypes.File,
    MessageTypes.Audio,
    MessageTypes.Video,
  }.contains(event.messageType);

  static String? _matrixReplyTarget(Event event) {
    final relation = event.content['m.relates_to'];
    if (relation is! Map) return null;
    final inReplyTo = relation['m.in_reply_to'];
    return inReplyTo is Map ? inReplyTo['event_id']?.toString() : null;
  }

  static String _uniqueMediaPath(
    Set<String> used,
    DateTime timestamp,
    String messageId,
    String originalName,
  ) {
    final date = timestamp.toUtc().toIso8601String().replaceAll(':', '-');
    final safeId = _safeFileComponent(messageId);
    final id = safeId.length <= 24 ? safeId : safeId.substring(0, 24);
    final safeName = _safeFileComponent(originalName);
    final base = 'media/${date}_${id}_${safeName.isEmpty ? 'file' : safeName}';
    var candidate = base;
    var suffix = 2;
    while (!used.add(candidate)) {
      final extension = path.extension(base);
      final withoutExtension = extension.isEmpty
          ? base
          : base.substring(0, base.length - extension.length);
      candidate = '$withoutExtension-$suffix$extension';
      suffix++;
    }
    return candidate;
  }

  static String _safeFileComponent(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.length <= 100) return cleaned;
    return cleaned.substring(0, 100).trim();
  }

  static void _writeReadableRecord(
    StringBuffer output,
    Map<String, Object?> record,
  ) {
    final timestamp = DateTime.parse(record['timestamp']! as String).toLocal();
    output
      ..writeln('[$timestamp] ${record['sender_name']}')
      ..writeln(record['body']);
    final media = (record['media'] as List?)?.whereType<Map>() ?? const [];
    for (final attachment in media) {
      final location = attachment['archive_path'] ?? '[media unavailable]';
      output.writeln('Attachment: ${attachment['name']} — $location');
    }
    final reactions =
        (record['reactions'] as List?)?.whereType<Map>() ?? const [];
    for (final reaction in reactions) {
      output.writeln(
        'Reaction: ${reaction['emoji']} — ${reaction['author_name']}',
      );
    }
    output.writeln();
  }
}

class _ExportItem {
  final Event? event;
  final ArchiveMessage? importedMessage;

  const _ExportItem._({this.event, this.importedMessage});

  factory _ExportItem.matrix(Event event) => _ExportItem._(event: event);

  factory _ExportItem.imported(ArchiveMessage message) =>
      _ExportItem._(importedMessage: message);

  String get id => event?.eventId ?? importedMessage!.id;

  DateTime get timestamp => event?.originServerTs ?? importedMessage!.timestamp;
}

class _ExportRecord {
  final Map<String, Object?> json;
  final int mediaCount;
  final int missingMediaCount;
  final bool undecryptable;

  const _ExportRecord({
    required this.json,
    required this.mediaCount,
    required this.missingMediaCount,
    required this.undecryptable,
  });
}
