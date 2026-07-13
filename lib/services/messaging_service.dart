import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import 'package:cryptography/cryptography.dart';
import '../models/message.dart';
import '../models/delivery_status.dart';
import '../models/contact.dart';
import '../crypto/crypto_service.dart';
import 'core_bridge.dart';
import 'mailbox_client.dart';
import 'cover_traffic_manager.dart';
import 'tor_manager.dart';

/// Secure Messaging Service
///
/// ARCHITECTURE GUARANTEES:
/// - ALL messages are E2E encrypted (X3DH + Double Ratchet)
/// - Sender identity hidden via Sealed Sender
/// - Store-and-forward via mailboxes (NEVER direct device-to-device)
/// - Delivery receipts ONLY from cryptographic signatures
/// - Constant traffic via cover messaging
///
/// This service NEVER:
/// - Sends plaintext over the network
/// - Exposes sender identity in transport
/// - Contacts recipient devices directly
/// - Sets ✓✓ without cryptographic proof
class MessagingService extends ChangeNotifier {
  final CoreBridge _bridge;
  final TorManager _torManager;
  final _storage = const FlutterSecureStorage();
  final _uuid = const Uuid();

  /// Cryptographic services (E2E encryption, sealed sender)
  late final CryptoService _cryptoService;

  /// Transport layer (store-and-forward mailboxes)
  late final MailboxClient _mailboxClient;

  /// Metadata resistance (constant traffic patterns)
  late final CoverTrafficManager _coverTrafficManager;

  /// Messages indexed by contact ID
  final Map<String, List<Message>> _messages = {};

  /// Contact lookup by mailbox ID (NOT onion address)
  final Map<String, Contact> _contactsByMailbox = {};

  /// Pending delivery receipts awaiting confirmation
  final Map<String, PendingReceipt> _pendingReceipts = {};

  /// Seen receipt IDs (replay protection - TEST C)
  final Set<String> _seenReceiptIds = {};

  /// Sequence counter for message ordering
  int _sequenceCounter = 0;

  String? _error;
  String? get error => _error;

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  MessagingService(this._bridge, this._torManager);

  /// Ensure service is initialized with at least one mailbox server.
  Future<bool> ensureInitialized({
    required String mailboxAddress,
    int mailboxPort = 80,
  }) async {
    if (_isInitialized) return true;

    if (mailboxAddress.trim().isEmpty) {
      _error = 'Mailbox server is not configured.';
      notifyListeners();
      return false;
    }

    try {
      await initialize(
        mailboxServers: [
          MailboxConfig(
            onionAddress: mailboxAddress.trim(),
            port: mailboxPort,
          ),
        ],
      );
      return true;
    } catch (e) {
      _error = 'Failed to initialize messaging: $e';
      notifyListeners();
      return false;
    }
  }

  /// Initialize the messaging service with crypto and transport.
  Future<void> initialize({
    required List<MailboxConfig> mailboxServers,
    List<String> coverMailboxes = const [],
  }) async {
    if (_isInitialized) return;

    // Load our mailbox ID (persistent)
    final ourMailboxId = await _loadOrCreateMailboxId();
    final authSecret = await _loadOrCreateAuthSecret();

    // Generate or load identity key pair
    final identityKeyPair = await _loadOrCreateIdentityKeyPair();

    // Initialize crypto service with identity
    _cryptoService = CryptoService();
    await _cryptoService.initialize(
      identityKeyPair: identityKeyPair,
      mailboxId: ourMailboxId,
    );

    // Initialize mailbox client
    _mailboxClient = MailboxClient();
    await _mailboxClient.initialize(
      ourMailboxId: ourMailboxId,
      authSecret: authSecret,
      mailboxServers: mailboxServers,
    );

    // Publish our prekey bundle to mailbox
    final bundle = await _cryptoService.generatePrekeyBundle();
    final bundleJson = json.encode(bundle.toJson());
    await _mailboxClient.publishPrekeyBundle(bundleJson: bundleJson);

    // Initialize cover traffic manager
    _coverTrafficManager = CoverTrafficManager(
      mailboxClient: _mailboxClient,
      cryptoService: _cryptoService,
    );
    _coverTrafficManager.addCoverMailboxes(coverMailboxes);
    _coverTrafficManager.onEnvelopeReceived = _processIncomingEnvelope;
    _coverTrafficManager.start();

    _isInitialized = true;
    debugPrint('MessagingService: Initialized with cryptographic guarantees');
    notifyListeners();
  }

  /// Load or create persistent mailbox ID.
  Future<String> _loadOrCreateMailboxId() async {
    final stored = await _storage.read(key: 'mailbox_id');
    if (stored != null) return stored;

    final mailboxId = _uuid.v4();
    await _storage.write(key: 'mailbox_id', value: mailboxId);
    return mailboxId;
  }

  /// Load or create mailbox authentication secret.
  Future<String> _loadOrCreateAuthSecret() async {
    final stored = await _storage.read(key: 'mailbox_auth_secret');
    if (stored != null) return stored;

    final secret = _uuid.v4() + _uuid.v4(); // 64 chars
    await _storage.write(key: 'mailbox_auth_secret', value: secret);
    return secret;
  }

  /// Load or create persistent identity key pair.
  Future<SimpleKeyPair> _loadOrCreateIdentityKeyPair() async {
    final stored = await _storage.read(key: 'identity_keypair');
    final algorithm = X25519();

    if (stored != null) {
      try {
        final decoded = json.decode(stored) as Map<String, dynamic>;
        final privateBytes = _hexToBytes(decoded['private'] as String);
        final publicBytes = _hexToBytes(decoded['public'] as String);
        return SimpleKeyPairData(
          privateBytes,
          publicKey: SimplePublicKey(publicBytes, type: KeyPairType.x25519),
          type: KeyPairType.x25519,
        );
      } catch (e) {
        debugPrint('MessagingService: Failed to load identity key pair: $e');
      }
    }

    // Generate new key pair
    final keyPair = await algorithm.newKeyPair();
    final privateKey = await keyPair.extractPrivateKeyBytes();
    final publicKey = await keyPair.extractPublicKey();

    // Store for persistence
    final data = json.encode({
      'private': _bytesToHex(privateKey),
      'public': _bytesToHex(publicKey.bytes),
    });
    await _storage.write(key: 'identity_keypair', value: data);

    return keyPair;
  }

  /// Convert bytes to hex string.
  String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Register a contact for secure messaging.
  ///
  /// SECURITY: Only verified contacts can receive messages.
  Future<void> registerContact(Contact contact) async {
    if (contact.mailboxId.isEmpty) {
      debugPrint('MessagingService: Cannot register contact without mailbox ID');
      return;
    }

    if (!contact.isVerified) {
      debugPrint('MessagingService: WARNING - Contact ${contact.label} not verified');
      // Allow registration but block messaging (enforced in sendTextMessage)
    }

    _contactsByMailbox[contact.mailboxId] = contact;

    // Fetch and register prekey bundle for session establishment
    final bundleJson = await _mailboxClient.fetchPrekeyBundle(
      contactMailboxId: contact.mailboxId,
    );

    if (bundleJson != null) {
      // Convert public key from base64/hex to bytes
      final publicKeyBytes = _hexToBytes(contact.publicKey);
      
      await _cryptoService.registerContact(
        contactId: contact.id,
        publicKey: publicKeyBytes,
        mailboxId: contact.mailboxId,
        sealedSenderKey: publicKeyBytes, // Use same key for sealed sender
      );
      debugPrint('MessagingService: Registered contact ${contact.label}');
    }
  }
  
  /// Convert hex string to bytes.
  List<int> _hexToBytes(String hex) {
    final result = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      result.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return result;
  }

  /// Get messages for a specific contact.
  List<Message> getMessages(String contactId) {
    return List.unmodifiable(_messages[contactId] ?? []);
  }

  /// Load messages from local storage.
  Future<void> loadMessages(String contactId) async {
    try {
      final key = 'messages_$contactId';
      final stored = await _storage.read(key: key);
      
      if (stored != null) {
        final list = jsonDecode(stored) as List<dynamic>;
        _messages[contactId] = list
            .map((m) => Message.fromJson(m as Map<String, dynamic>))
            .toList();
        
        // Update sequence counter
        for (final msg in _messages[contactId]!) {
          if (msg.sequenceIndex > _sequenceCounter) {
            _sequenceCounter = msg.sequenceIndex;
          }
        }
        
        notifyListeners();
      } else {
        _messages[contactId] = [];
      }
    } catch (e) {
      debugPrint('Failed to load messages: $e');
      _messages[contactId] = [];
    }
  }

  /// Save messages to local storage.
  Future<void> _saveMessages(String contactId) async {
    try {
      final key = 'messages_$contactId';
      final list = _messages[contactId] ?? [];
      final json = jsonEncode(list.map((m) => m.toJson()).toList());
      await _storage.write(key: key, value: json);
    } catch (e) {
      debugPrint('Failed to save messages: $e');
    }
  }

  /// Send a securely encrypted text message to a verified contact.
  ///
  /// SECURITY GUARANTEES:
  /// - Message is E2E encrypted (X3DH + Double Ratchet)
  /// - Sender identity hidden (Sealed Sender)
  /// - Delivered via store-and-forward mailbox
  /// - Status is PENDING until cryptographic receipt received
  ///
  /// WILL FAIL if:
  /// - Contact is not verified
  /// - Contact has no mailbox ID
  /// - Crypto layer not initialized
  Future<bool> sendTextMessage({
    required String contactId,
    required String text,
    required Contact contact,
  }) async {
    _error = null;

    // SECURITY: Block messaging to unverified contacts
    if (!contact.isVerified) {
      _error = 'Cannot send to unverified contact. Verify identity first.';
      notifyListeners();
      return false;
    }

    // SECURITY: Require mailbox ID (not direct onion address)
    if (contact.mailboxId.isEmpty) {
      _error = 'Contact has no mailbox configured.';
      notifyListeners();
      return false;
    }

    if (!_isInitialized) {
      _error = 'Messaging service not initialized.';
      notifyListeners();
      return false;
    }

    try {
      _sequenceCounter++;
      final messageId = _uuid.v4();

      final message = Message(
        id: messageId,
        contactId: contactId,
        isOutgoing: true,
        type: MessageType.text,
        textContent: text,
        deliveryStatus: DeliveryStatus.pending, // PENDING until receipt
        sequenceIndex: _sequenceCounter,
      );

      // Add message locally first (shows as pending in UI)
      _addMessage(contactId, message);
      await _saveMessages(contactId);

      // Encrypt and seal message through crypto layer
      final envelope = await _cryptoService.encryptMessage(
        contactId: contactId,
        plaintext: utf8.encode(text),
        messageId: messageId,
      );

      if (envelope == null) {
        _error = 'Failed to encrypt message. Session may need refresh.';
        _updateDeliveryStatus(contactId, messageId, DeliveryStatus.failed);
        await _saveMessages(contactId);
        notifyListeners();
        return false;
      }

      // Track pending receipt (for ✓✓ verification)
      _pendingReceipts[messageId] = PendingReceipt(
        messageId: messageId,
        contactId: contactId,
        sentAt: DateTime.now(),
      );

      // Queue for delivery via cover traffic manager
      // Message will be sent at next transmission interval
      _coverTrafficManager.queueMessage(
        mailboxId: envelope.mailboxId,
        envelope: envelope.envelopeBytes,
      );

      // Update to SENT (but NOT delivered - that requires receipt)
      _updateDeliveryStatus(contactId, messageId, DeliveryStatus.sent);
      await _saveMessages(contactId);

      debugPrint('MessagingService: Message queued for $contactId (pending receipt)');
      return true;
    } catch (e) {
      _error = 'Failed to send message: $e';
      notifyListeners();
      return false;
    }
  }

  /// Process incoming sealed envelope.
  ///
  /// Called by CoverTrafficManager when envelopes are retrieved.
  Future<void> _processIncomingEnvelope(List<int> envelope) async {
    try {
      // Decrypt through crypto layer
      final incoming = await _cryptoService.processIncomingEnvelope(envelope);
      if (incoming == null) {
        debugPrint('MessagingService: Failed to decrypt envelope');
        return;
      }

      // Handle based on message type
      if (incoming.isDeliveryReceipt) {
        // This is a delivery receipt - verify and update status
        _handleCryptographicReceipt(incoming);
      } else {
        // This is a regular message
        _handleIncomingMessage(incoming);
      }
    } catch (e) {
      debugPrint('MessagingService: Error processing envelope: $e');
    }
  }

  /// Handle decrypted incoming message.
  void _handleIncomingMessage(IncomingMessage incoming) {
    // Use sender contact ID directly (already looked up in crypto layer)
    final contactId = incoming.senderContactId;
    if (contactId == null) {
      debugPrint('MessagingService: Unknown sender');
      return;
    }
    
    final contact = _contactsByMailbox.values
        .where((c) => c.id == contactId)
        .firstOrNull;
    if (contact == null) {
      debugPrint('MessagingService: Contact $contactId not found');
      return;
    }

    _sequenceCounter++;

    final message = Message(
      id: incoming.messageId ?? _uuid.v4(),
      contactId: contact.id,
      isOutgoing: false,
      type: MessageType.text,
      textContent: incoming.plaintext != null ? utf8.decode(incoming.plaintext!) : '',
      deliveryStatus: DeliveryStatus.delivered,
      sequenceIndex: _sequenceCounter,
    );

    _addMessage(contact.id, message);
    _saveMessages(contact.id);

    // Send cryptographic delivery receipt
    _sendDeliveryReceipt(
      contactId: contact.id,
      messageId: message.id,
    );
  }

  /// Handle verified cryptographic delivery receipt.
  ///
  /// This is the ONLY way a message can become ✓✓ (delivered).
  /// 
  /// REPLAY PROTECTION (TEST C):
  /// - Each receipt is tracked in _seenReceiptIds
  /// - Replayed receipts are silently ignored
  /// - Tampered receipts fail signature verification in crypto layer
  void _handleCryptographicReceipt(IncomingMessage incoming) {
    final messageId = incoming.messageId;
    if (messageId == null) return;

    // REPLAY PROTECTION: Check if we've seen this receipt before
    final receiptId = '${incoming.senderContactId}:$messageId';
    if (_seenReceiptIds.contains(receiptId)) {
      debugPrint('MessagingService: Replay detected for receipt $messageId - IGNORED');
      return;
    }

    final pending = _pendingReceipts.remove(messageId);
    if (pending == null) {
      // Unknown message - could be replay of old receipt or fake injection
      debugPrint('MessagingService: Receipt for unknown message $messageId - IGNORED');
      return;
    }

    // Signature was already verified by CryptoService
    // Mark as seen to prevent replay
    _seenReceiptIds.add(receiptId);

    // NOW we can show ✓✓
    _updateDeliveryStatus(pending.contactId, messageId, DeliveryStatus.delivered);
    _saveMessages(pending.contactId);

    debugPrint('MessagingService: Cryptographic receipt verified for $messageId');
  }

  /// Send cryptographic delivery receipt to sender.
  Future<void> _sendDeliveryReceipt({
    required String contactId,
    required String messageId,
  }) async {
    try {
      // Encode receipt as structured data
      final receiptData = utf8.encode('RECEIPT:$messageId');
      
      final envelope = await _cryptoService.encryptMessage(
        contactId: contactId,
        plaintext: receiptData,
        messageId: 'receipt_$messageId',
        isReceipt: true,
      );

      if (envelope != null) {
        _coverTrafficManager.queueMessage(
          mailboxId: envelope.mailboxId,
          envelope: envelope.envelopeBytes,
        );
      }
    } catch (e) {
      debugPrint('MessagingService: Failed to send receipt: $e');
    }
  }

  /// Find contact by sender identity key.
  /// NOTE: This is now primarily for legacy lookups.
  /// Prefer using senderContactId from IncomingMessage.
  Contact? _findContactBySender(String? senderIdentityKeyHex) {
    if (senderIdentityKeyHex == null) return null;
    for (final contact in _contactsByMailbox.values) {
      if (contact.publicKey == senderIdentityKeyHex ||
          contact.id == senderIdentityKeyHex) {
        return contact;
      }
    }
    return null;
  }
    
  /// Send an encrypted voice message.
  Future<bool> sendVoiceMessage({
    required String contactId,
    required String filePath,
    required Contact contact,
  }) async {
    _error = null;

    // SECURITY: Same guarantees as text messages
    if (!contact.isVerified) {
      _error = 'Cannot send to unverified contact.';
      notifyListeners();
      return false;
    }

    // TODO: Implement encrypted voice message support
    // For now, voice messages are stored locally only
    _error = 'Voice messages not yet supported over encrypted transport.';
    notifyListeners();
    return false;
  }

  /// Add a message to the local list.
  void _addMessage(String contactId, Message message) {
    _messages[contactId] ??= [];
    // Deduplicate by message ID
    final existing =
        _messages[contactId]!.indexWhere((m) => m.id == message.id);
    if (existing < 0) {
      _messages[contactId]!.add(message);
      notifyListeners();
    }
  }

  /// Update delivery status for a message.
  void _updateDeliveryStatus(
    String contactId,
    String messageId,
    DeliveryStatus status,
  ) {
    final list = _messages[contactId];
    if (list == null) return;

    final index = list.indexWhere((m) => m.id == messageId);
    if (index >= 0) {
      list[index] = list[index].copyWith(deliveryStatus: status);
      notifyListeners();
    }
  }

  /// Clear all messages for a contact.
  Future<void> clearMessages(String contactId) async {
    _messages[contactId] = [];
    await _storage.delete(key: 'messages_$contactId');
    notifyListeners();
  }

  /// Shutdown the messaging service.
  Future<void> shutdown() async {
    _coverTrafficManager.stop();
    _isInitialized = false;
  }

  @override
  void dispose() {
    _coverTrafficManager.dispose();
    super.dispose();
  }
}

/// Pending delivery receipt tracking.
class PendingReceipt {
  final String messageId;
  final String contactId;
  final DateTime sentAt;

  PendingReceipt({
    required this.messageId,
    required this.contactId,
    required this.sentAt,
  });
}
