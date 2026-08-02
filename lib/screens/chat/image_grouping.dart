import 'package:matrix/matrix.dart';

const patrickMediaBatchKey =
    'com.patricklamphier.patrick_messenger.media_batch_id';

const inferredImageBatchWindow = Duration(minutes: 2);

bool isGalleryImageEvent(Event event) =>
    event.type == EventTypes.Message && event.messageType == MessageTypes.Image;

String? imageBatchId(Event event) {
  final value = event.content[patrickMediaBatchKey];
  return value is String && value.isNotEmpty ? value : null;
}

bool imageEventIsReply(Event event) {
  final relation = event.content['m.relates_to'];
  return relation is Map && relation['m.in_reply_to'] is Map;
}

bool shouldGroupImageEvents(Event newer, Event older) {
  if (!isGalleryImageEvent(newer) || !isGalleryImageEvent(older)) {
    return false;
  }

  if (newer.senderId != older.senderId) return false;
  if (imageEventIsReply(newer) || imageEventIsReply(older)) return false;

  final newerBatch = imageBatchId(newer);
  final olderBatch = imageBatchId(older);

  if (newerBatch != null || olderBatch != null) {
    return newerBatch != null && newerBatch == olderBatch;
  }

  final difference = newer.originServerTs
      .difference(older.originServerTs)
      .inMilliseconds
      .abs();

  return difference <= inferredImageBatchWindow.inMilliseconds;
}
