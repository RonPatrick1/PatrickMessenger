import 'package:flutter/material.dart';

import '../../archive/archive_models.dart';
import '../../receipts/message_receipt_service.dart';

class MessageStatusIndicator extends StatelessWidget {
  final MessageReceiptSummary summary;
  final Color color;

  const MessageStatusIndicator({
    required this.summary,
    required this.color,
    super.key,
  });

  factory MessageStatusIndicator.imported({
    required ArchiveDeliveryState? state,
    required Color color,
  }) {
    final mapped = switch (state) {
      ArchiveDeliveryState.read ||
      ArchiveDeliveryState.viewed => MessageReceiptState.read,
      ArchiveDeliveryState.delivered => MessageReceiptState.delivered,
      ArchiveDeliveryState.sent || null => MessageReceiptState.sent,
    };
    return MessageStatusIndicator(
      summary: MessageReceiptSummary(
        mapped,
        mapped == MessageReceiptState.sent ? 0 : 1,
        1,
      ),
      color: color,
    );
  }

  @override
  Widget build(BuildContext context) {
    final second =
        summary.state == MessageReceiptState.delivered ||
        summary.state == MessageReceiptState.read;
    final filled = summary.state == MessageReceiptState.read;
    final partial =
        summary.total > 1 &&
        summary.completed > 0 &&
        summary.completed < summary.total;
    return Semantics(
      label: _label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: second ? 22 : 14,
            height: 15,
            child: Stack(
              children: [
                _CircleCheck(color: color, filled: filled),
                if (second)
                  Positioned(
                    left: 8,
                    child: _CircleCheck(color: color, filled: filled),
                  ),
              ],
            ),
          ),
          if (partial) ...[
            const SizedBox(width: 2),
            Text(
              '${summary.completed}/${summary.total}',
              style: TextStyle(color: color, fontSize: 9),
            ),
          ],
        ],
      ),
    );
  }

  String get _label => switch (summary.state) {
    MessageReceiptState.sending => 'Sending',
    MessageReceiptState.sent => 'Sent',
    MessageReceiptState.delivered =>
      'Delivered to ${summary.completed} of ${summary.total}',
    MessageReceiptState.read =>
      'Read by ${summary.completed} of ${summary.total}',
  };
}

class _CircleCheck extends StatelessWidget {
  final Color color;
  final bool filled;

  const _CircleCheck({required this.color, required this.filled});

  @override
  Widget build(BuildContext context) => Container(
    width: 14,
    height: 14,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: filled ? color : Colors.transparent,
      border: Border.all(color: color, width: 1.2),
    ),
    child: Icon(
      Icons.check,
      size: 10,
      color: filled ? Theme.of(context).colorScheme.surface : color,
    ),
  );
}
