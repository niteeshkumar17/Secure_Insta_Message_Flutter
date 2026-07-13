/// Unified Crypto Service
///
/// This is the single entry point for all cryptographic operations.
/// The presentation layer (Flutter UI) and transport layer (mailbox client)
/// interact ONLY through this service.
///
/// Responsibilities:
/// - X3DH session establishment
/// - Double Ratchet message encryption/decryption
/// - Sealed sender wrapping/unwrapping
/// - Receipt signing/verification
/// - Fixed-size padding
/// - Session state management
///
/// Security invariant:
/// - Plaintext NEVER leaves this service except to the UI layer
/// - The transport layer receives ONLY opaque sealed envelopes

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import 'x3dh.dart';
import 'double_ratchet.dart';
import 'sealed_sender.dart';
import 'padding.dart';

/// Message types in the protocol.
enum CryptoMessageType {
  /// Regular text/voice message
  message,

  /// Delivery receipt
  receipt,

  /// X3DH prekey bundle
  prekeyBundle,

  /// X3DH initial key exchange message
  keyExchange,
}

/// Cryptographic delivery receipt.
///
/// This is what ✓✓ actually means - a signed acknowledgment
/// from the recipient that they decrypted the message.
class DeliveryReceipt {
  /// ID of the message being acknowledged
  final String messageId;

  /// Contact ID of the sender (for routing)
  final String contactId;

  /// Ratchet epoch when message was decrypted
  final int ratchetEpoch;

  /// Ed25519 signature over (messageId || ratchetEpoch)
  final List<int> signature;

  const DeliveryReceipt({
    required this.messageId,
    required this.contactId,
    required this.ratchetEpoch,
    required this.signature,
  });

  /// Data that was signed.
  List<int> get signedData {
    final buffer = BytesBuilder();
    buffer.add(utf8.encode(messageId));
    buffer.add([
      (ratchetEpoch >> 24) & 0xFF,
      (ratchetEpoch >> 16) & 0xFF,
      (ratchetEpoch >> 8) & 0xFF,
      ratchetEpoch & 0xFF,
    ]);
    return buffer.toBytes();
  }

  List<int> encode() {
    final buffer = BytesBuilder();
    // Message ID (length-prefixed string)
    final msgIdBytes = utf8.encode(messageId);
    buffer.addByte(msgIdBytes.length);
    buffer.add(msgIdBytes);
    // Contact ID (length-prefixed string)
    final contactIdBytes = utf8.encode(contactId);
    buffer.addByte(contactIdBytes.length);
    buffer.add(contactIdBytes);
    // Ratchet epoch (4 bytes)
    buffer.add([
      (ratchetEpoch >> 24) & 0xFF,
      (ratchetEpoch >> 16) & 0xFF,
      (ratchetEpoch >> 8) & 0xFF,
      ratchetEpoch & 0xFF,
    ]);
    // Signature (64 bytes for Ed25519)
    buffer.add(signature);
    return buffer.toBytes();
  }

  factory DeliveryReceipt.decode(List<int> bytes) {
    var offset = 0;

    // Message ID
    final msgIdLen = bytes[offset];
    offset += 1;
    final messageId = utf8.decode(bytes.sublist(offset, offset + msgIdLen));
    offset += msgIdLen;

    // Contact ID
    final contactIdLen = bytes[offset];
    offset += 1;
    final contactId = utf8.decode(bytes.sublist(offset, offset + contactIdLen));
    offset += contactIdLen;

    // Ratchet epoch
    final ratchetEpoch = (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
    offset += 4;

    // Signature
    final signature = bytes.sublist(offset, offset + 64);

    return DeliveryReceipt(
      messageId: messageId,
      contactId: contactId,
      ratchetEpoch: ratchetEpoch,
      signature: signature,
    );
  }
}

/// Outgoing message ready for transport.
///
/// This is the ONLY thing the transport layer sees.
/// It is completely opaque - just bytes.
class OutgoingEnvelope {
  /// Target mailbox ID
  final String mailboxId;

  /// Sealed, padded envelope bytes
  final List<int> envelopeBytes;

  /// Local message ID for tracking
  final String messageId;

  const OutgoingEnvelope({
    required this.mailboxId,
    required this.envelopeBytes,
    required this.messageId,
  });
}

/// Incoming message after cryptographic processing.
class IncomingMessage {
  /// Message type
  final CryptoMessageType type;

  /// Verified sender contact ID (null if unknown sender)
  final String? senderContactId;

  /// Sender's public key (for unknown senders)
  final List<int>? senderPublicKey;

  /// Plaintext content as bytes (for messages)
  final List<int>? plaintext;

  /// Receipt data (for receipts)
  final DeliveryReceipt? receipt;

  /// Message ID
  final String? messageId;

  const IncomingMessage({
    required this.type,
    this.senderContactId,
    this.senderPublicKey,
    this.plaintext,
    this.receipt,
    this.messageId,
  });

  /// Whether this is a delivery receipt.
  bool get isDeliveryReceipt => type == CryptoMessageType.receipt;

  /// Sender identity key hex (alias for contactId lookup).
  String? get senderIdentityKeyHex => senderContactId;
}

/// Session state for a contact.
class ContactSession {
  /// Double Ratchet state
  RatchetState ratchetState;

  /// Is this session established?
  bool isEstablished;

  /// Contact's X25519 sealed sender public key
  List<int>? sealedSenderKey;

  ContactSession({
    required this.ratchetState,
    this.isEstablished = false,
    this.sealedSenderKey,
  });
}

/// Unified cryptographic service.
///
/// This service is the cryptographic boundary. Everything entering
/// or leaving the network goes through here.
class CryptoService extends ChangeNotifier {
  final _storage = const FlutterSecureStorage();
  final _uuid = const Uuid();

  final _x3dh = X3DH();
  final _ratchet = DoubleRatchet();
  final _sealedSender = SealedSender();
  final _padding = MessagePadding();
  final _ed25519 = Ed25519();

  /// Our identity keypair (Ed25519)
  SimpleKeyPair? _identityKeyPair;

  /// Our X25519 keypair for sealed sender
  SimpleKeyPair? _sealedSenderKeyPair;

  /// Our signed prekey (X25519)
  SimpleKeyPair? _signedPrekey;
  int _signedPrekeyId = 0;

  /// Our one-time prekeys (X25519)
  final Map<int, SimpleKeyPair> _oneTimePrekeys = {};
  int _nextOneTimePrekeyId = 0;

  /// Our mailbox ID
  String? _mailboxId;

  /// Sessions by contact ID
  final Map<String, ContactSession> _sessions = {};

  /// Contact public keys (for sender verification)
  final Map<String, List<int>> _contactPublicKeys = {};

  /// Contact mailbox IDs (for routing)
  final Map<String, String> _contactMailboxIds = {};

  /// Pending outgoing receipts
  final List<OutgoingEnvelope> _pendingReceipts = [];

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  String? get mailboxId => _mailboxId;

  /// Initialize the crypto service with an identity.
  Future<void> initialize({
    required SimpleKeyPair identityKeyPair,
    required String mailboxId,
  }) async {
    _identityKeyPair = identityKeyPair;
    _mailboxId = mailboxId;

    // Generate sealed sender keypair
    _sealedSenderKeyPair = await _sealedSender.generateSealedSenderKeyPair();

    // Generate signed prekey
    _signedPrekey = await _x3dh.generateSignedPrekey();
    _signedPrekeyId = DateTime.now().millisecondsSinceEpoch;

    // Generate initial one-time prekeys
    await _generateOneTimePrekeys(100);

    // Load persisted sessions
    await _loadSessions();

    _isInitialized = true;
    notifyListeners();
  }

  /// Generate our prekey bundle for publication.
  Future<PrekeyBundle> generatePrekeyBundle() async {
    if (_identityKeyPair == null || _signedPrekey == null) {
      throw StateError('Crypto service not initialized');
    }

    final identityPublic = await _identityKeyPair!.extractPublicKey();
    final signedPrekeyPublic = await _signedPrekey!.extractPublicKey();

    // Sign the prekey
    final signature = await _x3dh.signPrekey(
      _identityKeyPair!,
      signedPrekeyPublic.bytes,
    );

    // Get one-time prekey public keys
    final otpkPublics = <List<int>>[];
    final otpkIds = <int>[];
    for (final entry in _oneTimePrekeys.entries) {
      final publicKey = await entry.value.extractPublicKey();
      otpkPublics.add(publicKey.bytes);
      otpkIds.add(entry.key);
    }

    return PrekeyBundle(
      identityKey: identityPublic.bytes,
      signedPrekey: signedPrekeyPublic.bytes,
      signedPrekeySignature: signature,
      signedPrekeyId: _signedPrekeyId,
      oneTimePrekeys: otpkPublics,
      oneTimePrekeyIds: otpkIds,
    );
  }

  /// Register a contact for messaging.
  Future<void> registerContact({
    required String contactId,
    required List<int> publicKey,
    required String mailboxId,
    required List<int>? sealedSenderKey,
  }) async {
    _contactPublicKeys[contactId] = publicKey;
    _contactMailboxIds[contactId] = mailboxId;

    if (sealedSenderKey != null) {
      if (_sessions.containsKey(contactId)) {
        _sessions[contactId]!.sealedSenderKey = sealedSenderKey;
      }
    }

    await _saveContactKeys();
  }

  /// Establish a session with a contact.
  ///
  /// This performs X3DH key exchange and initializes Double Ratchet.
  Future<OutgoingEnvelope?> establishSession({
    required String contactId,
    required PrekeyBundle bundle,
  }) async {
    if (_identityKeyPair == null) {
      throw StateError('Crypto service not initialized');
    }

    // Perform X3DH
    final x3dhResult = await _x3dh.initiateKeyExchange(
      aliceIdentityKey: _identityKeyPair!,
      bobBundle: bundle,
    );

    // Initialize Double Ratchet as sender
    final ratchetState = await _ratchet.initializeAsSender(
      sharedSecret: x3dhResult.sharedSecret,
      remoteDhPublicKey: bundle.signedPrekey,
    );

    _sessions[contactId] = ContactSession(
      ratchetState: ratchetState,
      isEstablished: true,
      sealedSenderKey: bundle.identityKey, // Use identity key for sealed sender initially
    );

    // Store contact's bundle info
    _contactPublicKeys[contactId] = bundle.identityKey;
    if (_contactMailboxIds[contactId] == null) {
      debugPrint('Warning: No mailbox ID for contact $contactId');
    }

    await _saveSessions();

    return null; // No immediate message, session ready
  }

  /// Encrypt and seal a message for a contact.
  ///
  /// Returns a sealed envelope ready for transport.
  /// The transport layer CANNOT read the contents.
  ///
  /// Set [isReceipt] to true when sending delivery receipts.
  Future<OutgoingEnvelope?> encryptMessage({
    required String contactId,
    required List<int> plaintext,
    String? messageId,
    bool isReceipt = false,
  }) async {
    if (!_isInitialized) {
      throw StateError('Crypto service not initialized');
    }

    final session = _sessions[contactId];
    if (session == null || !session.isEstablished) {
      throw StateError('No established session with contact $contactId');
    }

    final recipientMailboxId = _contactMailboxIds[contactId];
    if (recipientMailboxId == null) {
      throw StateError('No mailbox ID for contact $contactId');
    }

    final msgId = messageId ?? _uuid.v4();

    // Build message payload
    final payload = _buildMessagePayload(
      type: isReceipt ? CryptoMessageType.receipt : CryptoMessageType.message,
      messageId: msgId,
      content: plaintext,
    );

    // Double Ratchet encrypt
    final encrypted = await _ratchet.encrypt(
      session.ratchetState,
      payload,
    );

    // Sealed sender wrap
    final identityPublic = await _identityKeyPair!.extractPublicKey();
    final sealedEnvelope = await _sealedSender.seal(
      senderIdentityKey: identityPublic.bytes,
      senderMailboxId: utf8.encode(_mailboxId!),
      recipientIdentityKey: session.sealedSenderKey ?? _contactPublicKeys[contactId]!,
      payload: encrypted.encode(),
    );

    // Pad to fixed size
    final paddedEnvelope = _padding.pad(sealedEnvelope.encode());

    await _saveSessions();

    return OutgoingEnvelope(
      mailboxId: recipientMailboxId,
      envelopeBytes: paddedEnvelope,
      messageId: msgId,
    );
  }

  /// Process an incoming sealed envelope.
  ///
  /// Returns the decrypted message with verified sender.
  Future<IncomingMessage?> processIncomingEnvelope(List<int> envelopeBytes) async {
    if (!_isInitialized || _sealedSenderKeyPair == null) {
      throw StateError('Crypto service not initialized');
    }

    try {
      // Remove padding
      final unpaddedBytes = _padding.unpad(envelopeBytes);

      // Decode sealed envelope
      final sealedEnvelope = SealedEnvelope.decode(unpaddedBytes);

      // Unseal to get sender and payload
      final unsealed = await _sealedSender.unseal(
        envelope: sealedEnvelope,
        recipientIdentityKeyPair: _sealedSenderKeyPair!,
      );

      // Look up sender by identity key
      final senderContactId = _findContactByPublicKey(unsealed.senderIdentityKey);

      if (senderContactId == null) {
        debugPrint('Received message from unknown sender');
        return IncomingMessage(
          type: CryptoMessageType.message,
          senderPublicKey: unsealed.senderIdentityKey,
          messageId: _uuid.v4(),
        );
      }

      // Get or create session
      var session = _sessions[senderContactId];
      if (session == null || !session.isEstablished) {
        debugPrint('No session for contact $senderContactId');
        return null;
      }

      // Decode Double Ratchet message
      final encryptedMessage = EncryptedMessage.decode(unsealed.payload);

      // Decrypt
      final decrypted = await _ratchet.decrypt(
        session.ratchetState,
        encryptedMessage,
      );

      // Parse payload
      final (type, messageId, content) = _parseMessagePayload(decrypted);

      await _saveSessions();

      if (type == CryptoMessageType.receipt) {
        // This is a delivery receipt
        final receipt = DeliveryReceipt.decode(content);

        // Verify signature
        final verified = await _verifyReceipt(receipt, senderContactId);
        if (!verified) {
          debugPrint('Invalid receipt signature from $senderContactId');
          return null;
        }

        return IncomingMessage(
          type: CryptoMessageType.receipt,
          senderContactId: senderContactId,
          receipt: receipt,
          messageId: messageId,
        );
      }

      // Generate and queue delivery receipt
      await _queueDeliveryReceipt(
        messageId: messageId,
        senderContactId: senderContactId,
        ratchetEpoch: session.ratchetState.ratchetEpoch,
      );

      return IncomingMessage(
        type: CryptoMessageType.message,
        senderContactId: senderContactId,
        plaintext: content,
        messageId: messageId,
      );
    } catch (e) {
      debugPrint('Failed to process envelope: $e');
      return null;
    }
  }

  /// Get pending outgoing receipts.
  List<OutgoingEnvelope> getPendingReceipts() {
    final receipts = List<OutgoingEnvelope>.from(_pendingReceipts);
    _pendingReceipts.clear();
    return receipts;
  }

  /// Generate a cover message (indistinguishable from real).
  List<int> generateCoverMessage() {
    return _padding.generateCoverMessage();
  }

  // --- Private methods ---

  Future<void> _generateOneTimePrekeys(int count) async {
    final newKeys = await _x3dh.generateOneTimePrekeys(count);
    for (final key in newKeys) {
      _oneTimePrekeys[_nextOneTimePrekeyId] = key;
      _nextOneTimePrekeyId++;
    }
  }

  String? _findContactByPublicKey(List<int> publicKey) {
    for (final entry in _contactPublicKeys.entries) {
      if (_listEquals(entry.value, publicKey)) {
        return entry.key;
      }
    }
    return null;
  }

  List<int> _buildMessagePayload({
    required CryptoMessageType type,
    required String messageId,
    required List<int> content,
  }) {
    final buffer = BytesBuilder();
    // Type byte
    buffer.addByte(type.index);
    // Message ID (length-prefixed)
    final msgIdBytes = utf8.encode(messageId);
    buffer.addByte(msgIdBytes.length);
    buffer.add(msgIdBytes);
    // Content
    buffer.add(content);
    return buffer.toBytes();
  }

  (CryptoMessageType, String, List<int>) _parseMessagePayload(List<int> payload) {
    var offset = 0;

    // Type byte
    final type = CryptoMessageType.values[payload[offset]];
    offset += 1;

    // Message ID
    final msgIdLen = payload[offset];
    offset += 1;
    final messageId = utf8.decode(payload.sublist(offset, offset + msgIdLen));
    offset += msgIdLen;

    // Content
    final content = payload.sublist(offset);

    return (type, messageId, content);
  }

  Future<void> _queueDeliveryReceipt({
    required String messageId,
    required String senderContactId,
    required int ratchetEpoch,
  }) async {
    if (_identityKeyPair == null) return;

    final session = _sessions[senderContactId];
    if (session == null || !session.isEstablished) return;

    final senderMailboxId = _contactMailboxIds[senderContactId];
    if (senderMailboxId == null) return;

    // Create receipt
    final receipt = DeliveryReceipt(
      messageId: messageId,
      contactId: senderContactId,
      ratchetEpoch: ratchetEpoch,
      signature: [], // Will be filled
    );

    // Sign the receipt
    final signedData = receipt.signedData;
    final signature = await _ed25519.sign(signedData, keyPair: _identityKeyPair!);

    final signedReceipt = DeliveryReceipt(
      messageId: messageId,
      contactId: senderContactId,
      ratchetEpoch: ratchetEpoch,
      signature: signature.bytes,
    );

    // Build payload
    final payload = _buildMessagePayload(
      type: CryptoMessageType.receipt,
      messageId: _uuid.v4(),
      content: signedReceipt.encode(),
    );

    // Encrypt with Double Ratchet
    final encrypted = await _ratchet.encrypt(session.ratchetState, payload);

    // Seal
    final identityPublic = await _identityKeyPair!.extractPublicKey();
    final sealedEnvelope = await _sealedSender.seal(
      senderIdentityKey: identityPublic.bytes,
      senderMailboxId: utf8.encode(_mailboxId!),
      recipientIdentityKey: session.sealedSenderKey ?? _contactPublicKeys[senderContactId]!,
      payload: encrypted.encode(),
    );

    // Pad
    final paddedEnvelope = _padding.pad(sealedEnvelope.encode());

    _pendingReceipts.add(OutgoingEnvelope(
      mailboxId: senderMailboxId,
      envelopeBytes: paddedEnvelope,
      messageId: _uuid.v4(),
    ));
  }

  Future<bool> _verifyReceipt(DeliveryReceipt receipt, String contactId) async {
    final publicKey = _contactPublicKeys[contactId];
    if (publicKey == null) return false;

    try {
      final pk = SimplePublicKey(publicKey, type: KeyPairType.ed25519);
      final sig = Signature(receipt.signature, publicKey: pk);
      return await _ed25519.verify(receipt.signedData, signature: sig);
    } catch (e) {
      return false;
    }
  }

  Future<void> _loadSessions() async {
    // Load from secure storage
    // Implementation depends on storage format
  }

  Future<void> _saveSessions() async {
    // Save to secure storage
    // Implementation depends on storage format
  }

  Future<void> _saveContactKeys() async {
    // Save to secure storage
  }

  bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
