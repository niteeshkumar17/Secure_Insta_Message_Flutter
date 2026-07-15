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
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import 'x3dh.dart';
import 'double_ratchet.dart';
import 'sealed_sender.dart';
import 'padding.dart';

class AsyncMutex {
  Future<void>? _currentFuture;

  Future<T> protect<T>(Future<T> Function() action) async {
    final previousFuture = _currentFuture;
    final completer = Completer<void>();
    _currentFuture = completer.future;

    try {
      if (previousFuture != null) {
        await previousFuture;
      }
      return await action();
    } finally {
      completer.complete();
    }
  }
}

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
  final _cryptoMutex = AsyncMutex();

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

  /// Check if a session has been established with a contact.
  bool hasSession(String contactId) {
    return _sessions.containsKey(contactId) && _sessions[contactId]!.isEstablished;
  }

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

    // Load persisted sessions and contact keys
    await _loadContactKeys();
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
    // Only register if not already registered OR if no session exists yet.
    // This preserves the X25519 identity public key mapped during session establishment.
    final hasActiveSession = _sessions.containsKey(contactId) && _sessions[contactId]!.isEstablished;
    if (!hasActiveSession || !_contactPublicKeys.containsKey(contactId)) {
      _contactPublicKeys[contactId] = publicKey;
    }
    _contactMailboxIds[contactId] = mailboxId;

    // Do NOT overwrite or touch the session's sealedSenderKey here,
    // as it is correctly managed by the session establishment flow
    // using the X25519 public key from the prekey bundle.
    await _saveContactKeys();
  }

  /// Remove all state for a contact (e.g. when contact is deleted).
  Future<void> removeContact(String contactId) async {
    _contactPublicKeys.remove(contactId);
    _contactMailboxIds.remove(contactId);
    _sessions.remove(contactId);
    
    await _saveContactKeys();
    await _saveSessions();
    
    debugPrint('CryptoService: Removed all state for contact $contactId');
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

    // Perform deterministic X3DH (we derive identical shared secrets)
    final x3dhResult = await _x3dh.initiateKeyExchange(
      aliceIdentityKey: _identityKeyPair!,
      bobBundle: bundle,
    );
    
    // Determine who is Initiator vs Responder by lexicographical sort of public keys
    final ourPubHex = _bytesToHex((await _identityKeyPair!.extractPublicKey()).bytes);
    final theirPubHex = _bytesToHex(bundle.identityKey);
    final isInitiator = ourPubHex.compareTo(theirPubHex) < 0;

    debugPrint('CryptoService: isInitiator=$isInitiator, our=${ourPubHex.substring(0, 16)}, their=${theirPubHex.substring(0, 16)}');

    // Both sides use symmetric initialization with deterministic chain keys
    final ratchetState = await _ratchet.initializeSymmetric(
      sharedSecret: x3dhResult.sharedSecret,
      isInitiator: isInitiator,
      dhKeyPair: await X25519().newKeyPair(),
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

    await _saveContactKeys();
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
    return _cryptoMutex.protect(() async {
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
      final recipKey = session.sealedSenderKey ?? _contactPublicKeys[contactId]!;
      debugPrint('SEAL: sender pub=${_bytesToHex(identityPublic.bytes).substring(0, 16)}...');
      debugPrint('SEAL: recip pub=${_bytesToHex(recipKey).substring(0, 16)}...');
      final sealedEnvelope = await _sealedSender.seal(
        senderIdentityKey: identityPublic.bytes,
        senderMailboxId: utf8.encode(_mailboxId!),
        recipientIdentityKey: recipKey,
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
    });
  }

  /// Process an incoming sealed envelope.
  ///
  /// Returns the decrypted message with verified sender.
  Future<IncomingMessage?> processIncomingEnvelope(List<int> envelopeBytes) async {
    return _cryptoMutex.protect(() async {
      if (!_isInitialized || _sealedSenderKeyPair == null) {
        throw StateError('Crypto service not initialized');
      }

      try {
        // Remove padding
        final unpaddedBytes = _padding.unpad(envelopeBytes);

        // Decode sealed envelope
        final sealedEnvelope = SealedEnvelope.decode(unpaddedBytes);

        // Unseal to get sender and payload
        // Use identity keypair since sender sealed with our identity public key
        final myPub = await _identityKeyPair!.extractPublicKey();
        debugPrint('UNSEAL: my pub=${_bytesToHex(myPub.bytes).substring(0, 16)}...');
        final unsealed = await _sealedSender.unseal(
          envelope: sealedEnvelope,
          recipientIdentityKeyPair: _identityKeyPair!,
        );

        debugPrint('UNSEAL: sender key=${_bytesToHex(unsealed.senderIdentityKey).substring(0, 16)}...');

        // Look up sender by identity key
        final senderContactId = _findContactByPublicKey(unsealed.senderIdentityKey);
        debugPrint('UNSEAL: known contacts=${_contactPublicKeys.keys.toList()}');
        for (final entry in _contactPublicKeys.entries) {
          debugPrint('UNSEAL: contact ${entry.key} key=${_bytesToHex(entry.value).substring(0, 16)}...');
        }

        if (senderContactId == null) {
          debugPrint('UNSEAL: Received message from UNKNOWN sender');
          return IncomingMessage(
            type: CryptoMessageType.message,
            senderPublicKey: unsealed.senderIdentityKey,
            messageId: _uuid.v4(),
          );
        }

        debugPrint('UNSEAL: sender matched to contact $senderContactId');

        // Get or create session
        var session = _sessions[senderContactId];
        if (session == null || !session.isEstablished) {
          debugPrint('UNSEAL: No session for contact $senderContactId, sessions=${_sessions.keys.toList()}');
          return null;
        }

        debugPrint('UNSEAL: session found, attempting ratchet decrypt');

        // Decode Double Ratchet message
        final encryptedMessage = EncryptedMessage.decode(unsealed.payload);

        // Decrypt
        final decrypted = await _ratchet.decrypt(
          session.ratchetState,
          encryptedMessage,
        );

        debugPrint('UNSEAL: ratchet decrypt SUCCESS');

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
    });
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
    final typeValue = payload[offset];
    offset += 1;
    final type = typeValue == CryptoMessageType.receipt.index
        ? CryptoMessageType.receipt
        : CryptoMessageType.message;

    // Message ID
    final msgIdLength = payload[offset];
    offset += 1;
    final msgIdBytes = payload.sublist(offset, offset + msgIdLength);
    final messageId = utf8.decode(msgIdBytes);
    offset += msgIdLength;

    // Content
    final content = payload.sublist(offset);

    return (type, messageId, content);
  }

  String _bytesToHex(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  List<int> _hexToBytes(String hex) {
    final result = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      result.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return result;
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
    try {
      final jsonStr = await _storage.read(key: 'double_ratchet_sessions_v1');
      if (jsonStr == null) {
        debugPrint('CryptoService: No persisted sessions found.');
        return;
      }

      final Map<String, dynamic> decoded = json.decode(jsonStr);
      _sessions.clear();

      for (final entry in decoded.entries) {
        final contactId = entry.key;
        final data = entry.value as Map<String, dynamic>;

        final isEstablished = data['is_established'] as bool? ?? false;
        final sealedSenderKeyStr = data['sealed_sender_key'] as String?;
        final sealedSenderKey = sealedSenderKeyStr != null ? _hexToBytes(sealedSenderKeyStr) : null;

        final stateData = data['ratchet_state'] as Map<String, dynamic>;
        final rootKey = _hexToBytes(stateData['root_key'] as String);

        final state = RatchetState(rootKey: rootKey);
        state.sendingChainKey = stateData['sending_chain_key'] != null ? _hexToBytes(stateData['sending_chain_key'] as String) : null;
        state.receivingChainKey = stateData['receiving_chain_key'] != null ? _hexToBytes(stateData['receiving_chain_key'] as String) : null;
        state.remoteDhPublicKey = stateData['remote_dh_public_key'] != null ? _hexToBytes(stateData['remote_dh_public_key'] as String) : null;
        state.sendingMessageNumber = stateData['sending_message_number'] as int? ?? 0;
        state.receivingMessageNumber = stateData['receiving_message_number'] as int? ?? 0;
        state.previousSendingChainLength = stateData['previous_sending_chain_length'] as int? ?? 0;
        state.ratchetEpoch = stateData['ratchet_epoch'] as int? ?? 0;

        final dhKeyPairData = stateData['dh_key_pair'] as Map<String, dynamic>?;
        if (dhKeyPairData != null) {
          final privateBytes = _hexToBytes(dhKeyPairData['private'] as String);
          final publicBytes = _hexToBytes(dhKeyPairData['public'] as String);
          state.dhKeyPair = SimpleKeyPairData(
            privateBytes,
            publicKey: SimplePublicKey(publicBytes, type: KeyPairType.x25519),
            type: KeyPairType.x25519,
          );
        }

        final skippedKeysList = stateData['skipped_keys'] as List?;
        if (skippedKeysList != null) {
          for (final item in skippedKeysList) {
            final dhPub = _hexToBytes(item['dh_pub'] as String);
            final msgNum = item['msg_num'] as int;
            final keyBytes = _hexToBytes(item['key'] as String);
            state.skippedMessageKeys[SkippedKeyId(dhPub, msgNum)] = keyBytes;
          }
        }

        _sessions[contactId] = ContactSession(
          ratchetState: state,
          isEstablished: isEstablished,
          sealedSenderKey: sealedSenderKey,
        );
      }

      debugPrint('CryptoService: Successfully loaded ${_sessions.length} sessions from storage.');
    } catch (e) {
      debugPrint('CryptoService: Error loading sessions: $e');
    }
  }

  Future<void> _saveSessions() async {
    try {
      final Map<String, dynamic> sessionsJson = {};
      for (final entry in _sessions.entries) {
        final contactId = entry.key;
        final session = entry.value;
        final state = session.ratchetState;

        Map<String, dynamic>? dhKeyPairJson;
        if (state.dhKeyPair != null) {
          final privateKeyBytes = await state.dhKeyPair!.extractPrivateKeyBytes();
          final publicKey = await state.dhKeyPair!.extractPublicKey();
          dhKeyPairJson = {
            'private': _bytesToHex(privateKeyBytes),
            'public': _bytesToHex(publicKey.bytes),
          };
        }

        final List<Map<String, dynamic>> skippedKeysList = [];
        state.skippedMessageKeys.forEach((keyId, keyBytes) {
          skippedKeysList.add({
            'dh_pub': _bytesToHex(keyId.dhPublicKey),
            'msg_num': keyId.messageNumber,
            'key': _bytesToHex(keyBytes),
          });
        });

        sessionsJson[contactId] = {
          'is_established': session.isEstablished,
          'sealed_sender_key': session.sealedSenderKey != null ? _bytesToHex(session.sealedSenderKey!) : null,
          'ratchet_state': {
            'root_key': _bytesToHex(state.rootKey),
            'sending_chain_key': state.sendingChainKey != null ? _bytesToHex(state.sendingChainKey!) : null,
            'receiving_chain_key': state.receivingChainKey != null ? _bytesToHex(state.receivingChainKey!) : null,
            'remote_dh_public_key': state.remoteDhPublicKey != null ? _bytesToHex(state.remoteDhPublicKey!) : null,
            'sending_message_number': state.sendingMessageNumber,
            'receiving_message_number': state.receivingMessageNumber,
            'previous_sending_chain_length': state.previousSendingChainLength,
            'ratchet_epoch': state.ratchetEpoch,
            'dh_key_pair': dhKeyPairJson,
            'skipped_keys': skippedKeysList,
          }
        };
      }

      final jsonStr = json.encode(sessionsJson);
      await _storage.write(key: 'double_ratchet_sessions_v1', value: jsonStr);
      debugPrint('CryptoService: Successfully saved ${_sessions.length} sessions to storage.');
    } catch (e) {
      debugPrint('CryptoService: Error saving sessions: $e');
    }
  }

  Future<void> _saveContactKeys() async {
    try {
      final Map<String, String> keysJson = {};
      _contactPublicKeys.forEach((contactId, keyBytes) {
        keysJson[contactId] = _bytesToHex(keyBytes);
      });
      await _storage.write(key: 'crypto_contact_public_keys_v1', value: json.encode(keysJson));

      final Map<String, String> mailboxesJson = {};
      _contactMailboxIds.forEach((contactId, mailboxId) {
        mailboxesJson[contactId] = mailboxId;
      });
      await _storage.write(key: 'crypto_contact_mailbox_ids_v1', value: json.encode(mailboxesJson));
      
      debugPrint('CryptoService: Saved contact keys and mailboxes.');
    } catch (e) {
      debugPrint('CryptoService: Error saving contact keys: $e');
    }
  }

  Future<void> _loadContactKeys() async {
    try {
      final keysStr = await _storage.read(key: 'crypto_contact_public_keys_v1');
      if (keysStr != null) {
        final Map<String, dynamic> decoded = json.decode(keysStr);
        decoded.forEach((contactId, keyHex) {
          _contactPublicKeys[contactId] = _hexToBytes(keyHex as String);
        });
      }

      final mailboxesStr = await _storage.read(key: 'crypto_contact_mailbox_ids_v1');
      if (mailboxesStr != null) {
        final Map<String, dynamic> decoded = json.decode(mailboxesStr);
        decoded.forEach((contactId, mailboxId) {
          _contactMailboxIds[contactId] = mailboxId as String;
        });
      }
      debugPrint('CryptoService: Loaded ${_contactPublicKeys.length} contact keys from storage.');
    } catch (e) {
      debugPrint('CryptoService: Error loading contact keys: $e');
    }
  }

  bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
