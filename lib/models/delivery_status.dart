/// Delivery status for messages.
///
/// Only two visual indicators are permitted:
///   ✓  = sent (local confirmation that message entered the network)
///   ✓✓ = delivered (cryptographic confirmation from the recipient)
///
/// The following are FORBIDDEN by the protocol:
///   - Read receipts
///   - Typing indicators
///   - Online/last-seen status
enum DeliveryStatus {
  /// Message is being prepared / queued.
  pending,

  /// ✓ Message sent into the network (queued in cover traffic stream).
  sent,

  /// ✓✓ Cryptographic delivery confirmation received from recipient.
  delivered,

  /// Message failed to send (e.g., Tor disconnected, kill-switch).
  failed;

  static DeliveryStatus fromString(String? value) {
    switch (value) {
      case 'sent':
        return DeliveryStatus.sent;
      case 'delivered':
        return DeliveryStatus.delivered;
      case 'failed':
        return DeliveryStatus.failed;
      default:
        return DeliveryStatus.pending;
    }
  }

  /// Display string for the delivery status.
  String get displayTick {
    switch (this) {
      case DeliveryStatus.pending:
        return '⏳';
      case DeliveryStatus.sent:
        return '✓';
      case DeliveryStatus.delivered:
        return '✓✓';
      case DeliveryStatus.failed:
        return '✗';
    }
  }
}

