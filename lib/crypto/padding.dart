/// Fixed-Size Message Padding
///
/// Ensures all messages are the same size to prevent traffic analysis.
/// Without padding, message size reveals information about content length,
/// which is a metadata leak.
///
/// Protocol:
/// 1. Prepend 4-byte length
/// 2. Append random padding to fixed size
/// 3. Encrypt entire padded block
///
/// On receive:
/// 1. Decrypt entire block
/// 2. Read 4-byte length
/// 3. Extract payload, discard padding

import 'dart:math';
import 'dart:typed_data';

/// Standard padded message size (32 KB).
///
/// This size is chosen to:
/// - Accommodate most text messages with room to spare
/// - Be large enough for voice messages
/// - Be uniform enough to prevent size-based classification
const int paddedMessageSize = 32768;

/// Maximum payload size (accounting for length prefix).
const int maxPayloadSize = paddedMessageSize - 4;

/// Padding operations for fixed-size messages.
class MessagePadding {
  final _random = Random.secure();

  /// Pad a message to fixed size.
  ///
  /// The result is exactly [paddedMessageSize] bytes.
  ///
  /// Throws if [payload] exceeds [maxPayloadSize].
  List<int> pad(List<int> payload) {
    if (payload.length > maxPayloadSize) {
      throw ArgumentError(
        'Payload too large: ${payload.length} > $maxPayloadSize',
      );
    }

    final buffer = BytesBuilder();

    // 4-byte length prefix (big-endian)
    final length = payload.length;
    buffer.add([
      (length >> 24) & 0xFF,
      (length >> 16) & 0xFF,
      (length >> 8) & 0xFF,
      length & 0xFF,
    ]);

    // Payload
    buffer.add(payload);

    // Random padding to fill remaining space
    final paddingNeeded = paddedMessageSize - 4 - payload.length;
    final padding = Uint8List(paddingNeeded);
    for (var i = 0; i < paddingNeeded; i++) {
      padding[i] = _random.nextInt(256);
    }
    buffer.add(padding);

    final result = buffer.toBytes();
    assert(result.length == paddedMessageSize);
    return result;
  }

  /// Remove padding and extract original payload.
  ///
  /// [paddedData] must be exactly [paddedMessageSize] bytes.
  List<int> unpad(List<int> paddedData) {
    if (paddedData.length != paddedMessageSize) {
      throw ArgumentError(
        'Invalid padded data size: ${paddedData.length} != $paddedMessageSize',
      );
    }

    // Read 4-byte length prefix
    final length = (paddedData[0] << 24) |
        (paddedData[1] << 16) |
        (paddedData[2] << 8) |
        paddedData[3];

    if (length < 0 || length > maxPayloadSize) {
      throw FormatException('Invalid payload length: $length');
    }

    // Extract payload
    return paddedData.sublist(4, 4 + length);
  }

  /// Generate a random cover message of standard size.
  ///
  /// Cover messages are indistinguishable from real messages
  /// at the transport layer.
  List<int> generateCoverMessage() {
    final cover = Uint8List(paddedMessageSize);
    for (var i = 0; i < paddedMessageSize; i++) {
      cover[i] = _random.nextInt(256);
    }
    return cover;
  }

  /// Check if data appears to be a properly padded message.
  ///
  /// Note: This doesn't verify the payload is valid, just that
  /// the size is correct.
  bool isValidPaddedSize(List<int> data) {
    return data.length == paddedMessageSize;
  }
}
