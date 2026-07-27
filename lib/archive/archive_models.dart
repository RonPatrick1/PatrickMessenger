import 'dart:convert';

enum ArchiveMessageKind {
  text,
  media,
  deleted,
  call,
  sticker,
  viewOnce,
  update,
}

enum ArchiveDeliveryState { sent, delivered, read, viewed }

class ArchiveEncryptedFileRef {
  final String url;
  final String key;
  final String iv;
  final String sha256;
  final String name;
  final String mimeType;
  final int size;

  const ArchiveEncryptedFileRef({
    required this.url,
    required this.key,
    required this.iv,
    required this.sha256,
    required this.name,
    required this.mimeType,
    required this.size,
  });

  factory ArchiveEncryptedFileRef.fromJson(Map<String, dynamic> json) =>
      ArchiveEncryptedFileRef(
        url: json['url'] as String,
        key: json['key'] as String,
        iv: json['iv'] as String,
        sha256: json['sha256'] as String,
        name: json['name'] as String? ?? 'file',
        mimeType: json['mime_type'] as String? ?? 'application/octet-stream',
        size: (json['size'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
    'url': url,
    'key': key,
    'iv': iv,
    'sha256': sha256,
    'name': name,
    'mime_type': mimeType,
    'size': size,
  };
}

class ArchiveAttachment {
  final String id;
  final String name;
  final String mimeType;
  final int size;
  final int? width;
  final int? height;
  final String? caption;
  final String? ocrText;
  final ArchiveEncryptedFileRef? file;

  const ArchiveAttachment({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.size,
    this.width,
    this.height,
    this.caption,
    this.ocrText,
    this.file,
  });

  bool get missing => file == null;
  bool get isImage => mimeType.startsWith('image/');

  factory ArchiveAttachment.fromJson(Map<String, dynamic> json) =>
      ArchiveAttachment(
        id: json['id'] as String,
        name: json['name'] as String? ?? 'attachment',
        mimeType: json['mime_type'] as String? ?? 'application/octet-stream',
        size: (json['size'] as num?)?.toInt() ?? 0,
        width: (json['width'] as num?)?.toInt(),
        height: (json['height'] as num?)?.toInt(),
        caption: json['caption'] as String?,
        ocrText: json['ocr_text'] as String?,
        file: json['file'] is Map
            ? ArchiveEncryptedFileRef.fromJson(
                Map<String, dynamic>.from(json['file'] as Map),
              )
            : null,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'mime_type': mimeType,
    'size': size,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (caption != null && caption!.isNotEmpty) 'caption': caption,
    if (ocrText != null && ocrText!.isNotEmpty) 'ocr_text': ocrText,
    if (file != null) 'file': file!.toJson(),
  };

  ArchiveAttachment copyWith({
    ArchiveEncryptedFileRef? file,
    String? ocrText,
  }) => ArchiveAttachment(
    id: id,
    name: name,
    mimeType: mimeType,
    size: size,
    width: width,
    height: height,
    caption: caption,
    ocrText: ocrText ?? this.ocrText,
    file: file ?? this.file,
  );
}

class ArchiveReaction {
  final String authorMatrixId;
  final String authorName;
  final String emoji;
  final DateTime timestamp;

  const ArchiveReaction({
    required this.authorMatrixId,
    required this.authorName,
    required this.emoji,
    required this.timestamp,
  });

  factory ArchiveReaction.fromJson(Map<String, dynamic> json) =>
      ArchiveReaction(
        authorMatrixId: json['author_id'] as String,
        authorName: json['author_name'] as String,
        emoji: json['emoji'] as String,
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          (json['timestamp'] as num).toInt(),
        ),
      );

  Map<String, dynamic> toJson() => {
    'author_id': authorMatrixId,
    'author_name': authorName,
    'emoji': emoji,
    'timestamp': timestamp.millisecondsSinceEpoch,
  };
}

class ArchiveMessage {
  final String id;
  final String authorMatrixId;
  final String authorName;
  final DateTime timestamp;
  final ArchiveMessageKind kind;
  final String body;
  final bool edited;
  final bool deleted;
  final String? replyToId;
  final ArchiveDeliveryState? deliveryState;
  final List<ArchiveAttachment> attachments;
  final List<ArchiveReaction> reactions;
  final List<String> revisions;

  const ArchiveMessage({
    required this.id,
    required this.authorMatrixId,
    required this.authorName,
    required this.timestamp,
    required this.kind,
    required this.body,
    required this.edited,
    required this.deleted,
    required this.attachments,
    required this.reactions,
    required this.revisions,
    this.replyToId,
    this.deliveryState,
  });

  factory ArchiveMessage.fromJson(Map<String, dynamic> json) => ArchiveMessage(
    id: json['id'] as String,
    authorMatrixId: json['author_id'] as String,
    authorName: json['author_name'] as String,
    timestamp: DateTime.fromMillisecondsSinceEpoch(
      (json['timestamp'] as num).toInt(),
    ),
    kind: ArchiveMessageKind.values.byName(json['kind'] as String),
    body: json['body'] as String? ?? '',
    edited: json['edited'] as bool? ?? false,
    deleted: json['deleted'] as bool? ?? false,
    replyToId: json['reply_to_id'] as String?,
    deliveryState: json['delivery_state'] == null
        ? null
        : ArchiveDeliveryState.values.byName(json['delivery_state'] as String),
    attachments: (json['attachments'] as List? ?? const [])
        .map(
          (item) => ArchiveAttachment.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList(growable: false),
    reactions: (json['reactions'] as List? ?? const [])
        .map(
          (item) =>
              ArchiveReaction.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList(growable: false),
    revisions: (json['revisions'] as List? ?? const []).cast<String>(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'author_id': authorMatrixId,
    'author_name': authorName,
    'timestamp': timestamp.millisecondsSinceEpoch,
    'kind': kind.name,
    'body': body,
    'edited': edited,
    'deleted': deleted,
    if (replyToId != null) 'reply_to_id': replyToId,
    if (deliveryState != null) 'delivery_state': deliveryState!.name,
    'attachments': attachments.map((item) => item.toJson()).toList(),
    'reactions': reactions.map((item) => item.toJson()).toList(),
    'revisions': revisions,
  };

  String get searchableText => [
    body,
    ...attachments.expand(
      (item) => [item.name, item.caption ?? '', item.ocrText ?? ''],
    ),
  ].where((part) => part.trim().isNotEmpty).join('\n');

  ArchiveMessage copyWith({
    String? body,
    bool? edited,
    bool? deleted,
    List<ArchiveReaction>? reactions,
  }) => ArchiveMessage(
    id: id,
    authorMatrixId: authorMatrixId,
    authorName: authorName,
    timestamp: timestamp,
    kind: kind,
    body: body ?? this.body,
    edited: edited ?? this.edited,
    deleted: deleted ?? this.deleted,
    replyToId: replyToId,
    deliveryState: deliveryState,
    attachments: attachments,
    reactions: reactions ?? this.reactions,
    revisions: revisions,
  );
}

class ArchiveManifest {
  final int schemaVersion;
  final String importId;
  final String roomId;
  final String source;
  final DateTime importedAt;
  final int messageCount;
  final DateTime firstTimestamp;
  final DateTime lastTimestamp;
  final List<ArchiveEncryptedFileRef> chunks;

  const ArchiveManifest({
    required this.schemaVersion,
    required this.importId,
    required this.roomId,
    required this.source,
    required this.importedAt,
    required this.messageCount,
    required this.firstTimestamp,
    required this.lastTimestamp,
    required this.chunks,
  });

  factory ArchiveManifest.fromJson(Map<String, dynamic> json) =>
      ArchiveManifest(
        schemaVersion: (json['schema_version'] as num).toInt(),
        importId: json['import_id'] as String,
        roomId: json['room_id'] as String,
        source: json['source'] as String,
        importedAt: DateTime.fromMillisecondsSinceEpoch(
          (json['imported_at'] as num).toInt(),
        ),
        messageCount: (json['message_count'] as num).toInt(),
        firstTimestamp: DateTime.fromMillisecondsSinceEpoch(
          (json['first_timestamp'] as num).toInt(),
        ),
        lastTimestamp: DateTime.fromMillisecondsSinceEpoch(
          (json['last_timestamp'] as num).toInt(),
        ),
        chunks: (json['chunks'] as List)
            .map(
              (item) => ArchiveEncryptedFileRef.fromJson(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .toList(growable: false),
      );

  Map<String, dynamic> toJson() => {
    'schema_version': schemaVersion,
    'import_id': importId,
    'room_id': roomId,
    'source': source,
    'imported_at': importedAt.millisecondsSinceEpoch,
    'message_count': messageCount,
    'first_timestamp': firstTimestamp.millisecondsSinceEpoch,
    'last_timestamp': lastTimestamp.millisecondsSinceEpoch,
    'chunks': chunks.map((chunk) => chunk.toJson()).toList(),
  };

  List<int> encode() => utf8.encode(jsonEncode(toJson()));
}
