const archiveSchemaVersion = 1;

const archiveManifestEventType =
    'com.patricklamphier.patrick_messenger.archive.manifest';
const archivePointerStateType =
    'com.patricklamphier.patrick_messenger.archive.pointer';
const archiveOverlayEventType =
    'com.patricklamphier.patrick_messenger.archive.overlay';
const archiveReplyKey =
    'com.patricklamphier.patrick_messenger.archive.reply_to';
const mediaOcrKey = 'com.patricklamphier.patrick_messenger.media_ocr';
const messageRecipientsKey =
    'com.patricklamphier.patrick_messenger.receipt_recipients';
const receiptEventType = 'com.patricklamphier.patrick_messenger.receipt';
const readReceiptsAccountDataType =
    'com.patricklamphier.patrick_messenger.read_receipts';

const controlRelationType = 'com.patricklamphier.patrick_messenger.control';
const liamChatterRelationType =
    'com.patricklamphier.patrick_messenger.liam_chatter';
const controlPushRuleId =
    'com.patricklamphier.patrick_messenger.silent_control';

Map<String, dynamic> controlRelation(String eventId) => {
  'rel_type': controlRelationType,
  'event_id': eventId,
};
