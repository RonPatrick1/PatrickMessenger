import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'archive_models.dart';

typedef SignalMediaOcr = Future<String?> Function(File file, String mimeType);

class SignalExportScan {
  final String accountName;
  final String accountRecipientId;
  final String contactName;
  final String contactRecipientId;
  final String chatId;
  final int messageCount;
  final DateTime firstTimestamp;
  final DateTime lastTimestamp;

  const SignalExportScan({
    required this.accountName,
    required this.accountRecipientId,
    required this.contactName,
    required this.contactRecipientId,
    required this.chatId,
    required this.messageCount,
    required this.firstTimestamp,
    required this.lastTimestamp,
  });
}

class SignalParseResult {
  final SignalExportScan scan;
  final List<ArchiveMessage> messages;
  final int availableMedia;
  final int missingMedia;
  final int unreferencedMedia;
  final Map<String, File> mediaFiles;

  const SignalParseResult({
    required this.scan,
    required this.messages,
    required this.availableMedia,
    required this.missingMedia,
    required this.unreferencedMedia,
    required this.mediaFiles,
  });
}

class SignalExportParser {
  final Directory source;
  final String accountMatrixId;
  final String contactMatrixId;
  final String contactNameHint;
  final SignalMediaOcr? recognizeText;

  SignalExportParser({
    required this.source,
    required this.accountMatrixId,
    required this.contactMatrixId,
    this.contactNameHint = 'Elizabeth Patrick',
    this.recognizeText,
  });

  File get _mainFile => File(path.join(source.path, 'main.jsonl'));
  Directory get _mediaDirectory => Directory(path.join(source.path, 'files'));

  Future<SignalExportScan> scan() async {
    if (!await _mainFile.exists()) {
      throw FormatException('The Signal export has no main.jsonl file.');
    }

    var accountName = '';
    var selfRecipientId = '';
    final recipients = <String, String>{};
    final chatRecipients = <String, String>{};
    final counts = <String, int>{};
    final first = <String, int>{};
    final last = <String, int>{};

    await for (final line
        in _mainFile
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      final root = jsonDecode(line) as Map<String, dynamic>;
      final account = root['account'];
      if (account is Map) {
        accountName = _joinName(
          account['givenName'] as String?,
          account['familyName'] as String?,
        );
      }
      final recipient = root['recipient'];
      if (recipient is Map) {
        final id = recipient['id']?.toString();
        if (id == null) continue;
        if (recipient['self'] is Map) selfRecipientId = id;
        final contact = recipient['contact'];
        if (contact is Map) {
          final name = _joinName(
            (contact['profileGivenName'] ?? contact['systemGivenName'])
                as String?,
            (contact['profileFamilyName'] ?? contact['systemFamilyName'])
                as String?,
          );
          if (name.isNotEmpty) recipients[id] = name;
        }
      }
      final chat = root['chat'];
      if (chat is Map) {
        final id = chat['id']?.toString();
        final recipientId = chat['recipientId']?.toString();
        if (id != null && recipientId != null) {
          chatRecipients[id] = recipientId;
        }
      }
      final item = root['chatItem'];
      if (item is Map) {
        final chatId = item['chatId']?.toString();
        final timestamp = int.tryParse(item['dateSent']?.toString() ?? '');
        if (chatId == null || timestamp == null) continue;
        counts[chatId] = (counts[chatId] ?? 0) + 1;
        first[chatId] = first[chatId] == null
            ? timestamp
            : (first[chatId]! < timestamp ? first[chatId]! : timestamp);
        last[chatId] = last[chatId] == null
            ? timestamp
            : (last[chatId]! > timestamp ? last[chatId]! : timestamp);
      }
    }

    if (selfRecipientId.isEmpty) {
      throw const FormatException('The Signal account recipient is missing.');
    }
    final candidates = chatRecipients.entries.where((entry) {
      final name = recipients[entry.value] ?? '';
      return name.toLowerCase() == contactNameHint.toLowerCase();
    }).toList();
    if (candidates.isEmpty) {
      throw FormatException(
        'No Signal conversation named "$contactNameHint" was found.',
      );
    }
    candidates.sort(
      (a, b) => (counts[b.key] ?? 0).compareTo(counts[a.key] ?? 0),
    );
    final selected = candidates.first;
    final count = counts[selected.key] ?? 0;
    if (count == 0) {
      throw FormatException('The "$contactNameHint" conversation is empty.');
    }

    return SignalExportScan(
      accountName: accountName.isEmpty ? 'Signal account' : accountName,
      accountRecipientId: selfRecipientId,
      contactName: recipients[selected.value] ?? contactNameHint,
      contactRecipientId: selected.value,
      chatId: selected.key,
      messageCount: count,
      firstTimestamp: DateTime.fromMillisecondsSinceEpoch(first[selected.key]!),
      lastTimestamp: DateTime.fromMillisecondsSinceEpoch(last[selected.key]!),
    );
  }

  Future<SignalParseResult> parse({
    void Function(String message)? onProgress,
  }) async {
    final export = await scan();
    onProgress?.call('Hashing Signal media…');
    final mediaByHash = await _indexMediaFiles();
    final referencedHashes = <String>{};
    final timestampIds = <String, String>{};
    final occurrences = <String, int>{};
    final rawMessages = <_RawArchiveMessage>[];
    final ocrCache = <String, String?>{};
    var unresolvedMediaReferences = 0;

    var processed = 0;
    await for (final line
        in _mainFile
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      final root = jsonDecode(line) as Map<String, dynamic>;
      final itemValue = root['chatItem'];
      if (itemValue is! Map ||
          itemValue['chatId']?.toString() != export.chatId) {
        continue;
      }
      final item = Map<String, dynamic>.from(itemValue);
      final timestamp = int.parse(item['dateSent'].toString());
      final authorId = item['authorId'].toString();
      final occurrenceKey = '$authorId:$timestamp';
      final occurrence = occurrences.update(
        occurrenceKey,
        (value) => value + 1,
        ifAbsent: () => 0,
      );
      final stableSource = '${export.chatId}:$authorId:$timestamp:$occurrence';
      final id = 'signal_${sha256.convert(utf8.encode(stableSource))}';
      timestampIds.putIfAbsent('$authorId:$timestamp', () => id);

      final mine = authorId == export.accountRecipientId;
      final authorMatrixId = mine ? accountMatrixId : contactMatrixId;
      final authorName = mine ? export.accountName : export.contactName;
      final standard = item['standardMessage'] is Map
          ? Map<String, dynamic>.from(item['standardMessage'] as Map)
          : null;
      var body = standard?['text'] is Map
          ? ((standard!['text'] as Map)['body']?.toString() ?? '')
          : '';
      var kind = ArchiveMessageKind.text;
      var deleted = item['remoteDeletedMessage'] is Map;
      if (deleted) {
        kind = ArchiveMessageKind.deleted;
        body = 'Message deleted';
      } else if (item['updateMessage'] is Map) {
        final update = item['updateMessage'] as Map;
        if (update['individualCall'] is Map) {
          kind = ArchiveMessageKind.call;
          final call = update['individualCall'] as Map;
          final direction = call['direction']?.toString().toLowerCase() ?? '';
          final type = call['type']?.toString().toLowerCase() ?? 'call';
          body = '${_title(direction)} ${type.replaceAll('_', ' ')}';
        } else {
          kind = ArchiveMessageKind.update;
          body = 'Signal security information updated';
        }
      } else if (item['viewOnceMessage'] is Map) {
        kind = ArchiveMessageKind.viewOnce;
        body = 'View-once media is no longer available';
      } else if (item['stickerMessage'] is Map) {
        kind = ArchiveMessageKind.sticker;
        final sticker = (item['stickerMessage'] as Map)['sticker'];
        body = sticker is Map
            ? sticker['emoji']?.toString() ?? 'Sticker'
            : 'Sticker';
      }

      final attachments = <ArchiveAttachment>[];
      final attachmentValues = standard?['attachments'];
      if (attachmentValues is List) {
        if (attachmentValues.isNotEmpty && body.isEmpty) {
          kind = ArchiveMessageKind.media;
        }
        for (final attachmentValue in attachmentValues.whereType<Map>()) {
          final pointer = attachmentValue['pointer'];
          if (pointer is! Map) continue;
          final locator = pointer['locatorInfo'];
          final hashBase64 = locator is Map
              ? locator['plaintextHash']?.toString()
              : null;
          final hashHex = hashBase64 == null
              ? ''
              : _base64HashToHex(hashBase64);
          if (hashHex.isNotEmpty) referencedHashes.add(hashHex);
          if (hashHex.isEmpty) unresolvedMediaReferences++;
          final media = mediaByHash[hashHex];
          final mimeType =
              pointer['contentType']?.toString() ??
              _mimeFromExtension(media?.path ?? '');
          String? ocrText;
          if (media != null &&
              mimeType.startsWith('image/') &&
              recognizeText != null) {
            ocrText = ocrCache[hashHex];
            if (!ocrCache.containsKey(hashHex)) {
              ocrText = await recognizeText!(media, mimeType);
              ocrCache[hashHex] = ocrText;
            }
          }
          attachments.add(
            ArchiveAttachment(
              id: hashHex.isEmpty ? '${id}_${attachments.length}' : hashHex,
              name: pointer['fileName']?.toString().trim().isNotEmpty == true
                  ? pointer['fileName'].toString()
                  : media == null
                  ? 'attachment'
                  : path.basename(media.path),
              mimeType: mimeType,
              size:
                  int.tryParse(
                    locator is Map ? locator['size']?.toString() ?? '' : '',
                  ) ??
                  (media == null ? 0 : await media.length()),
              width: int.tryParse(pointer['width']?.toString() ?? ''),
              height: int.tryParse(pointer['height']?.toString() ?? ''),
              caption: pointer['caption']?.toString(),
              ocrText: ocrText,
              file: null,
            ),
          );
        }
      }

      final linkPreviews = standard?['linkPreview'];
      if (linkPreviews is List) {
        for (final preview in linkPreviews.whereType<Map>()) {
          final pointer = preview['image'];
          if (pointer is! Map) continue;
          final locator = pointer['locatorInfo'];
          final hashBase64 = locator is Map
              ? locator['plaintextHash']?.toString()
              : null;
          final hashHex = hashBase64 == null
              ? ''
              : _base64HashToHex(hashBase64);
          if (hashHex.isNotEmpty) referencedHashes.add(hashHex);
          if (hashHex.isEmpty) unresolvedMediaReferences++;
          final media = mediaByHash[hashHex];
          final mimeType =
              pointer['contentType']?.toString() ??
              _mimeFromExtension(media?.path ?? '');
          String? ocrText;
          if (media != null &&
              mimeType.startsWith('image/') &&
              recognizeText != null) {
            if (!ocrCache.containsKey(hashHex)) {
              ocrCache[hashHex] = await recognizeText!(media, mimeType);
            }
            ocrText = ocrCache[hashHex];
          }
          final caption = [
            preview['title']?.toString() ?? '',
            preview['description']?.toString() ?? '',
            preview['url']?.toString() ?? '',
          ].where((part) => part.trim().isNotEmpty).join('\n');
          attachments.add(
            ArchiveAttachment(
              id: hashHex.isEmpty
                  ? '${id}_link_${attachments.length}'
                  : hashHex,
              name: media == null ? 'link-preview' : path.basename(media.path),
              mimeType: mimeType,
              size: media == null ? 0 : await media.length(),
              width: int.tryParse(pointer['width']?.toString() ?? ''),
              height: int.tryParse(pointer['height']?.toString() ?? ''),
              caption: caption,
              ocrText: ocrText,
              file: null,
            ),
          );
        }
      }

      final sticker = item['stickerMessage'] is Map
          ? (item['stickerMessage'] as Map)['sticker']
          : null;
      final stickerPointer = sticker is Map ? sticker['data'] : null;
      if (stickerPointer is Map) {
        final locator = stickerPointer['locatorInfo'];
        final hashBase64 = locator is Map
            ? locator['plaintextHash']?.toString()
            : null;
        final hashHex = hashBase64 == null ? '' : _base64HashToHex(hashBase64);
        if (hashHex.isNotEmpty) referencedHashes.add(hashHex);
        if (hashHex.isEmpty) unresolvedMediaReferences++;
        final media = mediaByHash[hashHex];
        final mimeType =
            stickerPointer['contentType']?.toString() ??
            _mimeFromExtension(media?.path ?? '');
        attachments.add(
          ArchiveAttachment(
            id: hashHex.isEmpty ? '${id}_sticker' : hashHex,
            name: media == null ? 'sticker' : path.basename(media.path),
            mimeType: mimeType,
            size: media == null ? 0 : await media.length(),
            width: int.tryParse(stickerPointer['width']?.toString() ?? ''),
            height: int.tryParse(stickerPointer['height']?.toString() ?? ''),
            file: null,
          ),
        );
      }

      final reactions = <ArchiveReaction>[];
      final reactionValues = standard?['reactions'];
      if (reactionValues is List) {
        for (final value in reactionValues.whereType<Map>()) {
          final reactionAuthor = value['authorId']?.toString();
          final reactionMine = reactionAuthor == export.accountRecipientId;
          reactions.add(
            ArchiveReaction(
              authorMatrixId: reactionMine ? accountMatrixId : contactMatrixId,
              authorName: reactionMine
                  ? export.accountName
                  : export.contactName,
              emoji: value['emoji']?.toString() ?? '',
              timestamp: DateTime.fromMillisecondsSinceEpoch(
                int.tryParse(value['sentTimestamp']?.toString() ?? '') ??
                    timestamp,
              ),
            ),
          );
        }
      }

      final revisions = <String>[];
      final revisionValues = item['revisions'];
      if (revisionValues is List) {
        for (final value in revisionValues.whereType<Map>()) {
          final revisionMessage = value['standardMessage'];
          final text = revisionMessage is Map && revisionMessage['text'] is Map
              ? (revisionMessage['text'] as Map)['body']?.toString()
              : null;
          if (text != null && text.isNotEmpty && !revisions.contains(text)) {
            revisions.add(text);
          }
        }
      }

      String? quotedAuthor;
      int? quotedTimestamp;
      final quote = standard?['quote'];
      if (quote is Map) {
        quotedAuthor = quote['authorId']?.toString();
        quotedTimestamp = int.tryParse(
          quote['targetSentTimestamp']?.toString() ?? '',
        );
      }

      rawMessages.add(
        _RawArchiveMessage(
          message: ArchiveMessage(
            id: id,
            authorMatrixId: authorMatrixId,
            authorName: authorName,
            timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp),
            kind: kind,
            body: body,
            edited: revisions.isNotEmpty,
            deleted: deleted,
            attachments: attachments,
            reactions: reactions,
            revisions: revisions,
            deliveryState: mine ? _deliveryState(item) : null,
          ),
          quotedAuthorId: quotedAuthor,
          quotedTimestamp: quotedTimestamp,
        ),
      );
      processed++;
      if (processed % 1000 == 0) {
        onProgress?.call(
          'Parsed $processed of ${export.messageCount} messages…',
        );
      }
    }

    final messages =
        rawMessages
            .map((raw) {
              final replyId =
                  raw.quotedAuthorId == null || raw.quotedTimestamp == null
                  ? null
                  : timestampIds['${raw.quotedAuthorId}:${raw.quotedTimestamp}'];
              final message = raw.message;
              return ArchiveMessage(
                id: message.id,
                authorMatrixId: message.authorMatrixId,
                authorName: message.authorName,
                timestamp: message.timestamp,
                kind: message.kind,
                body: message.body,
                edited: message.edited,
                deleted: message.deleted,
                replyToId: replyId,
                deliveryState: message.deliveryState,
                attachments: message.attachments,
                reactions: message.reactions,
                revisions: message.revisions,
              );
            })
            .toList(growable: false)
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    final available = referencedHashes.where(mediaByHash.containsKey).length;
    return SignalParseResult(
      scan: export,
      messages: messages,
      availableMedia: available,
      missingMedia:
          referencedHashes.length - available + unresolvedMediaReferences,
      unreferencedMedia: mediaByHash.keys
          .where((hash) => !referencedHashes.contains(hash))
          .length,
      mediaFiles: Map.unmodifiable(mediaByHash),
    );
  }

  Future<Map<String, File>> _indexMediaFiles() async {
    final result = <String, File>{};
    if (!await _mediaDirectory.exists()) return result;
    await for (final entity in _mediaDirectory.list(recursive: true)) {
      if (entity is! File) continue;
      final digest = await sha256.bind(entity.openRead()).first;
      result.putIfAbsent(digest.toString(), () => entity);
    }
    return result;
  }
}

class _RawArchiveMessage {
  final ArchiveMessage message;
  final String? quotedAuthorId;
  final int? quotedTimestamp;

  const _RawArchiveMessage({
    required this.message,
    this.quotedAuthorId,
    this.quotedTimestamp,
  });
}

ArchiveDeliveryState _deliveryState(Map<String, dynamic> item) {
  final outgoing = item['outgoing'];
  if (outgoing is! Map || outgoing['sendStatus'] is! List) {
    return ArchiveDeliveryState.sent;
  }
  var state = ArchiveDeliveryState.sent;
  for (final value in (outgoing['sendStatus'] as List).whereType<Map>()) {
    if (value['viewed'] is Map) return ArchiveDeliveryState.viewed;
    if (value['read'] is Map) state = ArchiveDeliveryState.read;
    if (value['delivered'] is Map && state == ArchiveDeliveryState.sent) {
      state = ArchiveDeliveryState.delivered;
    }
  }
  return state;
}

String _joinName(String? given, String? family) => [
  given?.trim() ?? '',
  family?.trim() ?? '',
].where((part) => part.isNotEmpty).join(' ');

String _base64HashToHex(String value) {
  try {
    return base64
        .decode(base64.normalize(value))
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  } catch (_) {
    return '';
  }
}

String _mimeFromExtension(String filePath) {
  switch (path.extension(filePath).toLowerCase()) {
    case '.jpg' || '.jpeg':
      return 'image/jpeg';
    case '.png':
      return 'image/png';
    case '.gif':
      return 'image/gif';
    case '.webp':
      return 'image/webp';
    case '.mp4':
      return 'video/mp4';
    case '.mpeg':
      return 'video/mpeg';
    case '.aac':
      return 'audio/aac';
    case '.pdf':
      return 'application/pdf';
    default:
      return 'application/octet-stream';
  }
}

String _title(String value) =>
    value.isEmpty ? '' : '${value[0].toUpperCase()}${value.substring(1)}';
