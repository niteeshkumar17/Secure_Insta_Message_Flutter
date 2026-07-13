/// Delivery status for messages.
///
/// SECURITY-CRITICAL SEMANTICS:
///
/// Delivery confirmation requires cryptographic proof:
///   - ✓ (sent) = Message queued to store-and-forward mailbox
///   - ✓✓ (delivered) = Signed receipt from recipient's identity key
///
/// ✓✓ REQUIRES:
///   1. Recipient retrieved from their mailbox
///   2. Recipient decrypted the message
///   3. Recipient signed a receipt with their Ed25519 identity key
///   4. Receipt verified against stored contact public key
///
/// ✓✓ DOES NOT mean:
///   - Message was read (no read receipts)
///   - Recipient is online (async delivery)
///   - HTTP 200 from any server (that proves nothing)
///
/// The following are FORBIDDEN by the protocol:
///   - Read receipts
///   - Typing indicators  
///   - Online/last-seen status
///   - Any status derived from transport HTTP responses
enum DeliveryStatus {
  /// Message is being prepared / encrypted.
  pending,

  /// ✓ Message encrypted and submitted to mailbox network.
  /// Does NOT indicate recipient has retrieved it.
  sent,

  /// ✓✓ Cryptographic delivery receipt verified.
  /// Recipient's Ed25519 signature confirmed.
  delivered,

  /// Message could not be sent (kill-switch, session error, etc).
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

