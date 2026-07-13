/// Sealed Sender Protocol Implementation
///
/// Implements anonymous sender envelopes. The mailbox/transport layer
/// cannot identify who sent a message - only the recipient can decrypt
/// and discover the sender's identity.
///
/// Protocol:
/// 1. Generate ephemeral X25519 keypair
/// 2. DH with recipient's identity key to derive encryption key
/// 3. Encrypt payload (containing sender identity + message) with AES-GCM
/// 4. Output: ephemeral public key + encrypted payload
///
/// Security properties:
/// - Sender anonymity: Transport sees only ephemeral key
/// - Recipient binding: Only recipient can decrypt
/// - Sender authentication: Sender identity inside envelope

import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// Sealed envelope structure.
///
/// This is what gets sent over the network. The mailbox/transport
/// layer sees only this - it cannot identify the sender.
class SealedEnvelope {
  /// Ephemeral public key for decryption (32 bytes)
  final List<int> ephemeralPublicKey;

  /// Encrypted payload (sender identity + message)
  final List<int> ciphertext;

  /// Authentication tag
  final List<int> tag;

  /// Nonce for decryption
  final List<int> nonce;

  const SealedEnvelope({
    required this.ephemeralPublicKey,
    required this.ciphertext,
    required this.tag,
    required this.nonce,
  });

  /// Encode to bytes for transmission.
  List<int> encode() {
    final buffer = BytesBuilder();
    // Version byte
    buffer.addByte(0x01);
    // Ephemeral public key (32 bytes)
    buffer.add(ephemeralPublicKey);
    // Nonce length (1 byte) + nonce
    buffer.addByte(nonce.length);
    buffer.add(nonce);
    // Tag length (1 byte) + tag
    buffer.addByte(tag.length);
    buffer.add(tag);
    // Ciphertext length (4 bytes) + ciphertext
    final ctLen = ciphertext.length;
    buffer.add([
      (ctLen >> 24) & 0xFF,
      (ctLen >> 16) & 0xFF,
      (ctLen >> 8) & 0xFF,
      ctLen & 0xFF,
    ]);
    buffer.add(ciphertext);
    return buffer.toBytes();
  }

  /// Decode from bytes.
  factory SealedEnvelope.decode(List<int> bytes) {
    var offset = 0;

    // Version byte
    final version = bytes[offset];
    if (version != 0x01) {
      throw FormatException('Unsupported sealed envelope version: $version');
    }
    offset += 1;

    // Ephemeral public key (32 bytes)
    final ephemeralPublicKey = bytes.sublist(offset, offset + 32);
    offset += 32;

    // Nonce
    final nonceLen = bytes[offset];
    offset += 1;
    final nonce = bytes.sublist(offset, offset + nonceLen);
    offset += nonceLen;

    // Tag
    final tagLen = bytes[offset];
    offset += 1;
    final tag = bytes.sublist(offset, offset + tagLen);
    offset += tagLen;

    // Ciphertext length and data
    final ctLen = (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
    offset += 4;
    final ciphertext = bytes.sublist(offset, offset + ctLen);

    return SealedEnvelope(
      ephemeralPublicKey: ephemeralPublicKey,
      ciphertext: ciphertext,
      tag: tag,
      nonce: nonce,
    );
  }
}

/// Unsealed message contents.
///
/// After decryption, we can see the sender's identity and the
/// actual message payload.
class UnsealedMessage {
  /// Sender's identity public key
  final List<int> senderIdentityKey;

  /// Sender's mailbox ID (for replies)
  final List<int> senderMailboxId;

  /// The actual message payload (encrypted with Double Ratchet)
  final List<int> payload;

  const UnsealedMessage({
    required this.senderIdentityKey,
    required this.senderMailboxId,
    required this.payload,
  });

  /// Encode inner payload before encryption.
  List<int> encode() {
    final buffer = BytesBuilder();
    // Sender identity key length (1 byte) + key
    buffer.addByte(senderIdentityKey.length);
    buffer.add(senderIdentityKey);
    // Sender mailbox ID length (1 byte) + ID
    buffer.addByte(senderMailboxId.length);
    buffer.add(senderMailboxId);
    // Payload (remaining bytes)
    buffer.add(payload);
    return buffer.toBytes();
  }

  /// Decode inner payload after decryption.
  factory UnsealedMessage.decode(List<int> bytes) {
    var offset = 0;

    // Sender identity key
    final senderKeyLen = bytes[offset];
    offset += 1;
    final senderIdentityKey = bytes.sublist(offset, offset + senderKeyLen);
    offset += senderKeyLen;

    // Sender mailbox ID
    final mailboxIdLen = bytes[offset];
    offset += 1;
    final senderMailboxId = bytes.sublist(offset, offset + mailboxIdLen);
    offset += mailboxIdLen;

    // Payload
    final payload = bytes.sublist(offset);

    return UnsealedMessage(
      senderIdentityKey: senderIdentityKey,
      senderMailboxId: senderMailboxId,
      payload: payload,
    );
  }
}

/// Sealed Sender implementation.
class SealedSender {
  final _x25519 = X25519();
  final _aesGcm = AesGcm.with256bits();
  final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  static final _info =
      Uint8List.fromList('SecureInstaMessage_SealedSender'.codeUnits);

  /// Seal a message for a recipient.
  ///
  /// The resulting envelope hides the sender's identity from anyone
  /// except the recipient.
  ///
  /// Parameters:
  /// - [senderIdentityKey]: Sender's public identity key
  /// - [senderMailboxId]: Sender's mailbox ID for replies
  /// - [recipientIdentityKey]: Recipient's public identity key
  /// - [payload]: The encrypted message (from Double Ratchet)
  ///
  /// Returns: Sealed envelope bytes (opaque to transport)
  Future<SealedEnvelope> seal({
    required List<int> senderIdentityKey,
    required List<int> senderMailboxId,
    required List<int> recipientIdentityKey,
    required List<int> payload,
  }) async {
    // Generate ephemeral keypair
    final ephemeralKeyPair = await _x25519.newKeyPair();
    final ephemeralPublicKey = await ephemeralKeyPair.extractPublicKey();

    // DH to derive encryption key
    // Note: We need X25519 version of recipient's key
    // In practice, recipients should publish X25519 keys for sealed sender
    final recipientPublic =
        SimplePublicKey(recipientIdentityKey, type: KeyPairType.x25519);

    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: ephemeralKeyPair,
      remotePublicKey: recipientPublic,
    );

    // Derive envelope key using HKDF
    final envelopeKey = await _hkdf.deriveKey(
      secretKey: SecretKey(await sharedSecret.extractBytes()),
      nonce: ephemeralPublicKey.bytes,
      info: _info,
    );

    // Build inner message
    final innerMessage = UnsealedMessage(
      senderIdentityKey: senderIdentityKey,
      senderMailboxId: senderMailboxId,
      payload: payload,
    );

    // Encrypt inner message
    final nonce = _aesGcm.newNonce();
    final secretBox = await _aesGcm.encrypt(
      innerMessage.encode(),
      secretKey: envelopeKey,
      nonce: nonce,
      aad: ephemeralPublicKey.bytes, // Bind to ephemeral key
    );

    return SealedEnvelope(
      ephemeralPublicKey: ephemeralPublicKey.bytes,
      ciphertext: secretBox.cipherText,
      tag: secretBox.mac.bytes,
      nonce: nonce,
    );
  }

  /// Unseal an envelope.
  ///
  /// Only the recipient (who has the private key) can do this.
  ///
  /// Parameters:
  /// - [envelope]: The sealed envelope to open
  /// - [recipientIdentityKeyPair]: Recipient's identity keypair
  ///
  /// Returns: The unsealed message with sender identity and payload
  Future<UnsealedMessage> unseal({
    required SealedEnvelope envelope,
    required SimpleKeyPair recipientIdentityKeyPair,
  }) async {
    final ephemeralPublic = SimplePublicKey(
      envelope.ephemeralPublicKey,
      type: KeyPairType.x25519,
    );

    // DH to derive decryption key
    // Note: Convert Ed25519 to X25519 in real implementation
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: recipientIdentityKeyPair,
      remotePublicKey: ephemeralPublic,
    );

    // Derive envelope key
    final envelopeKey = await _hkdf.deriveKey(
      secretKey: SecretKey(await sharedSecret.extractBytes()),
      nonce: envelope.ephemeralPublicKey,
      info: _info,
    );

    // Decrypt
    final secretBox = SecretBox(
      envelope.ciphertext,
      nonce: envelope.nonce,
      mac: Mac(envelope.tag),
    );

    final decrypted = await _aesGcm.decrypt(
      secretBox,
      secretKey: envelopeKey,
      aad: envelope.ephemeralPublicKey,
    );

    return UnsealedMessage.decode(decrypted);
  }

  /// Create an X25519 keypair for sealed sender operations.
  ///
  /// Recipients should publish this alongside their Ed25519 identity key.
  Future<SimpleKeyPair> generateSealedSenderKeyPair() async {
    return await _x25519.newKeyPair();
  }
}
