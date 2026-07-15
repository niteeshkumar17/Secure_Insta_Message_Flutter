/// Double Ratchet Protocol Implementation
///
/// Implements the Signal Double Ratchet algorithm for forward-secure
/// and future-secure messaging. Used after X3DH key exchange.
///
/// Security properties:
/// - Forward secrecy: Compromise of current keys doesn't reveal past messages
/// - Future secrecy: Compromise of current keys is healed after ratchet step
/// - Out-of-order delivery: Handles messages arriving out of sequence
///
/// Protocol overview:
/// - Symmetric ratchet: KDF chain for deriving message keys
/// - DH ratchet: Periodic DH to refresh root key

import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// Maximum number of skipped message keys to store.
const int maxSkippedKeys = 1000;

/// Header sent with each encrypted message.
class MessageHeader {
  /// Current DH ratchet public key
  final List<int> dhPublicKey;

  /// Previous chain message count
  final int previousChainLength;

  /// Message number in current chain
  final int messageNumber;

  const MessageHeader({
    required this.dhPublicKey,
    required this.previousChainLength,
    required this.messageNumber,
  });

  List<int> encode() {
    final buffer = BytesBuilder();
    // DH public key (32 bytes)
    buffer.add(dhPublicKey);
    // Previous chain length (4 bytes, big-endian)
    buffer.add(_intToBytes(previousChainLength));
    // Message number (4 bytes, big-endian)
    buffer.add(_intToBytes(messageNumber));
    return buffer.toBytes();
  }

  factory MessageHeader.decode(List<int> bytes) {
    if (bytes.length < 40) {
      throw FormatException('Invalid header length');
    }
    return MessageHeader(
      dhPublicKey: bytes.sublist(0, 32),
      previousChainLength: _bytesToInt(bytes.sublist(32, 36)),
      messageNumber: _bytesToInt(bytes.sublist(36, 40)),
    );
  }

  static List<int> _intToBytes(int value) {
    return [
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ];
  }

  static int _bytesToInt(List<int> bytes) {
    return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
  }
}

/// Encrypted message output from Double Ratchet.
class EncryptedMessage {
  /// Message header (contains DH public key, counters)
  final MessageHeader header;

  /// Ciphertext (encrypted with message key)
  final List<int> ciphertext;

  /// Authentication tag (from AES-GCM)
  final List<int> tag;

  /// Nonce used for encryption
  final List<int> nonce;

  const EncryptedMessage({
    required this.header,
    required this.ciphertext,
    required this.tag,
    required this.nonce,
  });

  /// Encode to bytes for transmission.
  List<int> encode() {
    final headerBytes = header.encode();
    final buffer = BytesBuilder();
    // Header length (2 bytes)
    buffer.addByte((headerBytes.length >> 8) & 0xFF);
    buffer.addByte(headerBytes.length & 0xFF);
    // Header
    buffer.add(headerBytes);
    // Nonce length (1 byte) + nonce
    buffer.addByte(nonce.length);
    buffer.add(nonce);
    // Tag length (1 byte) + tag
    buffer.addByte(tag.length);
    buffer.add(tag);
    // Ciphertext (remaining bytes)
    buffer.add(ciphertext);
    return buffer.toBytes();
  }

  /// Decode from bytes.
  factory EncryptedMessage.decode(List<int> bytes) {
    var offset = 0;

    // Read header length
    final headerLength = (bytes[offset] << 8) | bytes[offset + 1];
    offset += 2;

    // Read header
    final header = MessageHeader.decode(bytes.sublist(offset, offset + headerLength));
    offset += headerLength;

    // Read nonce
    final nonceLength = bytes[offset];
    offset += 1;
    final nonce = bytes.sublist(offset, offset + nonceLength);
    offset += nonceLength;

    // Read tag
    final tagLength = bytes[offset];
    offset += 1;
    final tag = bytes.sublist(offset, offset + tagLength);
    offset += tagLength;

    // Remaining is ciphertext
    final ciphertext = bytes.sublist(offset);

    return EncryptedMessage(
      header: header,
      ciphertext: ciphertext,
      tag: tag,
      nonce: nonce,
    );
  }
}

/// Key for looking up skipped message keys.
class SkippedKeyId {
  final List<int> dhPublicKey;
  final int messageNumber;

  const SkippedKeyId(this.dhPublicKey, this.messageNumber);

  @override
  bool operator ==(Object other) {
    if (other is! SkippedKeyId) return false;
    if (messageNumber != other.messageNumber) return false;
    if (dhPublicKey.length != other.dhPublicKey.length) return false;
    for (var i = 0; i < dhPublicKey.length; i++) {
      if (dhPublicKey[i] != other.dhPublicKey[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(messageNumber, Object.hashAll(dhPublicKey));
}

/// Double Ratchet session state.
///
/// This state must be persisted between messages.
class RatchetState {
  /// Our current DH key pair
  SimpleKeyPair? dhKeyPair;

  /// Their current DH public key
  List<int>? remoteDhPublicKey;

  /// Root key (32 bytes)
  List<int> rootKey;

  /// Sending chain key
  List<int>? sendingChainKey;

  /// Receiving chain key
  List<int>? receivingChainKey;

  /// Sending message counter
  int sendingMessageNumber = 0;

  /// Receiving message counter
  int receivingMessageNumber = 0;

  /// Previous sending chain length (for header)
  int previousSendingChainLength = 0;

  /// Skipped message keys (for out-of-order delivery)
  final Map<SkippedKeyId, List<int>> skippedMessageKeys = {};

  /// Ratchet epoch (increments on each DH ratchet)
  int ratchetEpoch = 0;

  RatchetState({required this.rootKey});

  /// Export state for persistence.
  Map<String, dynamic> toJson() => {
        'root_key': _bytesToHex(rootKey),
        'sending_chain_key':
            sendingChainKey != null ? _bytesToHex(sendingChainKey!) : null,
        'receiving_chain_key':
            receivingChainKey != null ? _bytesToHex(receivingChainKey!) : null,
        'remote_dh_public_key':
            remoteDhPublicKey != null ? _bytesToHex(remoteDhPublicKey!) : null,
        'sending_message_number': sendingMessageNumber,
        'receiving_message_number': receivingMessageNumber,
        'previous_sending_chain_length': previousSendingChainLength,
        'ratchet_epoch': ratchetEpoch,
        // Note: DH key pair and skipped keys need separate secure storage
      };

  static String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static List<int> _hexToBytes(String hex) {
    final result = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      result.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return result;
  }
}

/// Double Ratchet algorithm implementation.
class DoubleRatchet {
  final _x25519 = X25519();
  final _aesGcm = AesGcm.with256bits();
  final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  static final _kdfRkInfo = Uint8List.fromList('SecureInstaMessage_RK'.codeUnits);
  static final _kdfCkInfo = Uint8List.fromList('SecureInstaMessage_CK'.codeUnits);

  /// Initialize the ratchet symmetrically.
  ///
  /// Both sides independently call this with the same shared secret
  /// from X3DH. Chain keys are derived deterministically so both sides
  /// get matching send/receive chains without exchanging messages.
  ///
  /// [isInitiator]: true if our public key is lexicographically lower.
  /// This determines which chain is for sending vs receiving.
  Future<RatchetState> initializeSymmetric({
    required List<int> sharedSecret,
    required bool isInitiator,
    required SimpleKeyPair dhKeyPair,
  }) async {
    final state = RatchetState(rootKey: sharedSecret);
    state.dhKeyPair = dhKeyPair;

    // Derive two chain keys deterministically from the shared secret
    // using HKDF with different info labels
    final inputKey = SecretKey(sharedSecret);

    final chainKeyA = await _hkdf.deriveKey(
      secretKey: inputKey,
      nonce: Uint8List(32),
      info: Uint8List.fromList('SecureInstaMessage_ChainA'.codeUnits),
    );
    final chainKeyB = await _hkdf.deriveKey(
      secretKey: inputKey,
      nonce: Uint8List(32),
      info: Uint8List.fromList('SecureInstaMessage_ChainB'.codeUnits),
    );

    final chainA = await chainKeyA.extractBytes();
    final chainB = await chainKeyB.extractBytes();

    // Initiator sends on A, receives on B
    // Responder sends on B, receives on A
    if (isInitiator) {
      state.sendingChainKey = chainA;
      state.receivingChainKey = chainB;
    } else {
      state.sendingChainKey = chainB;
      state.receivingChainKey = chainA;
    }

    // Also derive a root key for future DH ratchet steps
    final rootKeyDerived = await _hkdf.deriveKey(
      secretKey: inputKey,
      nonce: Uint8List(32),
      info: Uint8List.fromList('SecureInstaMessage_RootKey'.codeUnits),
    );
    state.rootKey = await rootKeyDerived.extractBytes();

    return state;
  }

  /// Encrypt a message.
  Future<EncryptedMessage> encrypt(
    RatchetState state,
    List<int> plaintext,
  ) async {
    // Advance sending chain key and get message key
    final (newChainKey, messageKey) =
        await _kdfChainKey(state.sendingChainKey!);
    state.sendingChainKey = newChainKey;

    // Build header
    final dhPublicKey = await state.dhKeyPair!.extractPublicKey();
    final header = MessageHeader(
      dhPublicKey: dhPublicKey.bytes,
      previousChainLength: state.previousSendingChainLength,
      messageNumber: state.sendingMessageNumber,
    );

    state.sendingMessageNumber++;

    // Encrypt with AES-GCM
    final nonce = AesGcm.with256bits().newNonce();
    final secretBox = await _aesGcm.encrypt(
      plaintext,
      secretKey: SecretKey(messageKey),
      nonce: nonce,
      aad: header.encode(), // Authenticate header
    );

    return EncryptedMessage(
      header: header,
      ciphertext: secretBox.cipherText,
      tag: secretBox.mac.bytes,
      nonce: nonce,
    );
  }

  /// Decrypt a message.
  Future<List<int>> decrypt(
    RatchetState state,
    EncryptedMessage message,
  ) async {
    // Try skipped message keys first
    final skippedId =
        SkippedKeyId(message.header.dhPublicKey, message.header.messageNumber);
    if (state.skippedMessageKeys.containsKey(skippedId)) {
      final messageKey = state.skippedMessageKeys.remove(skippedId)!;
      return _decryptWithKey(message, messageKey);
    }

    if (state.remoteDhPublicKey == null) {
      // First message received in symmetrically initialized session.
      // It might be symmetrically encrypted (unratcheted) or ratcheted.
      final savedReceivingChainKey = state.receivingChainKey;
      final savedReceivingMessageNumber = state.receivingMessageNumber;
      
      try {
        // Set temporarily for skipMessages
        state.remoteDhPublicKey = message.header.dhPublicKey;
        
        // Try unratcheted
        await _skipMessages(state, message.header.messageNumber);
        final (newChainKey, messageKey) = await _kdfChainKey(state.receivingChainKey!);
        final plaintext = await _decryptWithKey(message, messageKey);
        
        // Success! Unratcheted.
        state.receivingChainKey = newChainKey;
        state.receivingMessageNumber++;
        
        // Perform a Half-Ratchet so our next reply will trigger a full ratchet on their side
        state.dhKeyPair = await _x25519.newKeyPair();
        final remotePub = SimplePublicKey(state.remoteDhPublicKey!, type: KeyPairType.x25519);
        final dhOut = await _x25519.sharedSecretKey(keyPair: state.dhKeyPair!, remotePublicKey: remotePub);
        final (newRoot, sendChain) = await _kdfRootKey(state.rootKey, await dhOut.extractBytes());
        state.rootKey = newRoot;
        state.sendingChainKey = sendChain;
        state.previousSendingChainLength = state.sendingMessageNumber;
        state.sendingMessageNumber = 0;
        state.ratchetEpoch++;
        
        return plaintext;
      } catch (e) {
        // Failed. Must be ratcheted. Restore state and fall through to full DH ratchet.
        state.remoteDhPublicKey = null;
        state.receivingChainKey = savedReceivingChainKey;
        state.receivingMessageNumber = savedReceivingMessageNumber;
        // Also clear any accidentally skipped keys
        state.skippedMessageKeys.removeWhere((key, value) => _listEquals(key.dhPublicKey, message.header.dhPublicKey));
      }
    }

    // Check if we need to perform a DH ratchet
    if (state.remoteDhPublicKey == null ||
        !_listEquals(message.header.dhPublicKey, state.remoteDhPublicKey!)) {
      // Skip any remaining messages in the old chain
      await _skipMessages(state, message.header.previousChainLength);

      // Perform DH ratchet
      await _dhRatchet(state, message.header.dhPublicKey);
    }

    // Skip to the correct message number
    await _skipMessages(state, message.header.messageNumber);

    // Advance receiving chain key and get message key
    final (newChainKey, messageKey) =
        await _kdfChainKey(state.receivingChainKey!);
    state.receivingChainKey = newChainKey;
    state.receivingMessageNumber++;

    return _decryptWithKey(message, messageKey);
  }

  /// Decrypt with a specific message key.
  Future<List<int>> _decryptWithKey(
    EncryptedMessage message,
    List<int> messageKey,
  ) async {
    final secretBox = SecretBox(
      message.ciphertext,
      nonce: message.nonce,
      mac: Mac(message.tag),
    );

    return _aesGcm.decrypt(
      secretBox,
      secretKey: SecretKey(messageKey),
      aad: message.header.encode(),
    );
  }

  /// Perform a DH ratchet step.
  Future<void> _dhRatchet(RatchetState state, List<int> remoteDhPublic) async {
    state.previousSendingChainLength = state.sendingMessageNumber;
    state.sendingMessageNumber = 0;
    state.receivingMessageNumber = 0;
    state.remoteDhPublicKey = remoteDhPublic;
    state.ratchetEpoch++;

    final remotePublicKey =
        SimplePublicKey(remoteDhPublic, type: KeyPairType.x25519);

    // DH with our current key pair and their new public key
    final dhOutput = await _x25519.sharedSecretKey(
      keyPair: state.dhKeyPair!,
      remotePublicKey: remotePublicKey,
    );

    // Derive new root key and receiving chain key
    final (newRootKey, receivingChainKey) =
        await _kdfRootKey(state.rootKey, await dhOutput.extractBytes());
    state.rootKey = newRootKey;
    state.receivingChainKey = receivingChainKey;

    // Generate new DH key pair
    state.dhKeyPair = await _x25519.newKeyPair();

    // DH with new key pair and their public key
    final dhOutput2 = await _x25519.sharedSecretKey(
      keyPair: state.dhKeyPair!,
      remotePublicKey: remotePublicKey,
    );

    // Derive new root key and sending chain key
    final (newRootKey2, sendingChainKey) =
        await _kdfRootKey(state.rootKey, await dhOutput2.extractBytes());
    state.rootKey = newRootKey2;
    state.sendingChainKey = sendingChainKey;
  }

  /// Skip messages and store their keys for later.
  Future<void> _skipMessages(RatchetState state, int until) async {
    if (state.receivingChainKey == null) return;

    if (state.receivingMessageNumber + maxSkippedKeys < until) {
      throw Exception('Too many skipped messages');
    }

    while (state.receivingMessageNumber < until) {
      final (newChainKey, messageKey) =
          await _kdfChainKey(state.receivingChainKey!);
      state.receivingChainKey = newChainKey;

      if (state.remoteDhPublicKey != null) {
        final skippedId = SkippedKeyId(
          state.remoteDhPublicKey!,
          state.receivingMessageNumber,
        );
        state.skippedMessageKeys[skippedId] = messageKey;
      }

      state.receivingMessageNumber++;

      // Prune old skipped keys if too many
      if (state.skippedMessageKeys.length > maxSkippedKeys) {
        state.skippedMessageKeys.remove(state.skippedMessageKeys.keys.first);
      }
    }
  }

  /// KDF for deriving root key and chain key from DH output.
  Future<(List<int>, List<int>)> _kdfRootKey(
    List<int> rootKey,
    List<int> dhOutput,
  ) async {
    final inputKey = SecretKey([...rootKey, ...dhOutput]);
    
    // First derivation for root key
    final newRootKeyDerived = await _hkdf.deriveKey(
      secretKey: inputKey,
      nonce: Uint8List(32),
      info: Uint8List.fromList([..._kdfRkInfo, 0x01]),
    );
    final newRootKey = await newRootKeyDerived.extractBytes();

    // Second derivation for chain key
    final chainKeyDerived = await _hkdf.deriveKey(
      secretKey: inputKey,
      nonce: Uint8List(32),
      info: Uint8List.fromList([..._kdfRkInfo, 0x02]),
    );
    final chainKey = await chainKeyDerived.extractBytes();

    return (newRootKey, chainKey);
  }

  /// KDF for advancing chain key and deriving message key.
  Future<(List<int>, List<int>)> _kdfChainKey(List<int> chainKey) async {
    final inputKey = SecretKey(chainKey);

    // Derive new chain key
    final newChainKey = await _hkdf.deriveKey(
      secretKey: inputKey,
      nonce: Uint8List.fromList([0x01]),
      info: _kdfCkInfo,
    );

    // Derive message key
    final messageKey = await _hkdf.deriveKey(
      secretKey: inputKey,
      nonce: Uint8List.fromList([0x02]),
      info: _kdfCkInfo,
    );

    return (
      await newChainKey.extractBytes(),
      await messageKey.extractBytes(),
    );
  }

  bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
