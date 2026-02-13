import 'delivery_status.dart';

/// Message types supported by the protocol.
///
/// Mirrors MessageType from src/protocol/message.py in the core.
/// DO NOT add new types here — the protocol is frozen.
enum MessageType {
  text,
  voice,
  receipt,
  keyExchange,
  sessionReset,
}

/// Message model — presentation only.
///
/// Contains NO timestamps (timestamps are forbidden by the protocol).
/// Only coarse ordering is provided via [sequenceIndex].
///
/// Messages do NOT include:
/// - Timestamps (forbidden — metadata leak)
/// - Sender identity visible to server
/// - Read indicators (forbidden)
/// - Typing indicators (forbidden)
class Message {
  /// Random message ID (for deduplication, NOT tracking).
  final String id;

  /// The contact ID this message belongs to.
  final String contactId;

  /// Whether this message was sent by us.
  final bool isOutgoing;

  /// Message type.
  final MessageType type;

  /// Text content (for text messages).
  final String? textContent;

  /// Voice data reference (for voice messages).
  /// This is a local file path, not transmitted in cleartext.
  final String? voiceDataPath;

  /// Delivery status.
  final DeliveryStatus deliveryStatus;

  /// Coarse ordering index (NOT a timestamp).
  /// Used only for display ordering within a conversation.
  final int sequenceIndex;

  const Message({
    required this.id,
    required this.contactId,
    required this.isOutgoing,
    required this.type,
    this.textContent,
    this.voiceDataPath,
    this.deliveryStatus = DeliveryStatus.pending,
    this.sequenceIndex = 0,
  });

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        id: json['id'] as String? ?? '',
        contactId: json['contact_id'] as String? ?? '',
        isOutgoing: json['is_outgoing'] as bool? ?? false,
        type: _parseType(json['type'] as String?),
        textContent: json['text_content'] as String?,
        voiceDataPath: json['voice_data_path'] as String?,
        deliveryStatus:
            DeliveryStatus.fromString(json['delivery_status'] as String?),
        sequenceIndex: json['sequence_index'] as int? ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'contact_id': contactId,
        'is_outgoing': isOutgoing,
        'type': type.name,
        'text_content': textContent,
        'voice_data_path': voiceDataPath,
        'delivery_status': deliveryStatus.name,
        'sequence_index': sequenceIndex,
      };

  Message copyWith({DeliveryStatus? deliveryStatus}) => Message(
        id: id,
        contactId: contactId,
        isOutgoing: isOutgoing,
        type: type,
        textContent: textContent,
        voiceDataPath: voiceDataPath,
        deliveryStatus: deliveryStatus ?? this.deliveryStatus,
        sequenceIndex: sequenceIndex,
      );

  static MessageType _parseType(String? value) {
    switch (value) {
      case 'text':
        return MessageType.text;
      case 'voice':
        return MessageType.voice;
      case 'receipt':
        return MessageType.receipt;
      case 'key_exchange':
        return MessageType.keyExchange;
      case 'session_reset':
        return MessageType.sessionReset;
      default:
        return MessageType.text;
    }
  }
}

