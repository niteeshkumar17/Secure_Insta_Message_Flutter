import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart' as crypto_hash;
import 'package:uuid/uuid.dart';
import '../models/contact.dart';
import 'core_bridge.dart';

/// Service for contact management.
///
/// Contacts are added manually by exchanging public keys and
/// onion addresses out-of-band. There is:
/// - No contact syncing
/// - No phone number lookup
/// - No server-mediated discovery
/// - No automatic trust (TOFU is not used)
///
/// Uses local secure storage - no Python core required.
class ContactsService extends ChangeNotifier {
  final CoreBridge _bridge;
  final _storage = const FlutterSecureStorage();
  final _uuid = const Uuid();

  List<Contact> _contacts = [];
  List<Contact> get contacts => List.unmodifiable(_contacts);

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String? _error;
  String? get error => _error;

  ContactsService(this._bridge);

  /// Load all contacts from local secure storage.
  Future<void> loadContacts() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final contactsJson = await _storage.read(key: 'contacts_list');
      if (contactsJson != null) {
        final list = jsonDecode(contactsJson) as List<dynamic>;
        _contacts = list
            .map((c) => Contact.fromJson(c as Map<String, dynamic>))
            .toList();
      } else {
        _contacts = [];
      }
    } catch (e) {
      _error = 'Failed to load contacts: $e';
      _contacts = [];
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Save contacts to local secure storage.
  Future<void> _saveContacts() async {
    try {
      final contactsJson = jsonEncode(_contacts.map((c) => c.toJson()).toList());
      await _storage.write(key: 'contacts_list', value: contactsJson);
    } catch (e) {
      debugPrint('Failed to save contacts: $e');
    }
  }

  /// Add a contact manually by their public key and onion address.
  Future<bool> addContact({
    required String label,
    required String publicKey,
    required String onionAddress,
    required String mailboxId,
  }) async {
    _error = null;

    try {
      // Generate fingerprint from public key (SHA-256 of hex-decoded key)
      String fingerprint = '';
      if (publicKey.isNotEmpty) {
        try {
          final keyBytes = _hexToBytes(publicKey);
          final fingerprintBytes = crypto_hash.sha256.convert(keyBytes).bytes;
          fingerprint = _bytesToHex(fingerprintBytes.sublist(0, 16));
        } catch (e) {
          // If public key isn't valid hex, use hash of the string
          final fingerprintBytes = crypto_hash.sha256.convert(utf8.encode(publicKey)).bytes;
          fingerprint = _bytesToHex(fingerprintBytes.sublist(0, 16));
        }
      }

      final contact = Contact(
        id: _uuid.v4(),
        label: label,
        publicKey: publicKey,
        fingerprint: fingerprint,
        onionAddress: onionAddress,
        mailboxId: mailboxId,
        isVerified: false,
        hasSession: false,
      );

      _contacts.add(contact);
      await _saveContacts();
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Failed to add contact: $e';
      notifyListeners();
      return false;
    }
  }

  /// Remove a contact.
  Future<bool> removeContact(String contactId) async {
    try {
      _contacts.removeWhere((c) => c.id == contactId);
      await _saveContacts();
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Failed to remove contact: $e';
      notifyListeners();
      return false;
    }
  }

  /// Mark a contact as manually verified.
  ///
  /// The user must verify the fingerprint out-of-band (in person,
  /// secure channel, etc). The app does not verify automatically.
  Future<bool> verifyContact(String contactId) async {
    try {
      final index = _contacts.indexWhere((c) => c.id == contactId);
      if (index >= 0) {
        _contacts[index] = _contacts[index].copyWith(isVerified: true);
        await _saveContacts();
        notifyListeners();
        return true;
      }
      return false;
    } catch (e) {
      _error = 'Failed to verify contact: $e';
      notifyListeners();
      return false;
    }
  }

  /// Get a specific contact by ID.
  Contact? getContact(String contactId) {
    try {
      return _contacts.firstWhere((c) => c.id == contactId);
    } catch (_) {
      return null;
    }
  }

  /// Check if messaging is allowed to this contact.
  ///
  /// SECURITY: Returns true ONLY if:
  /// - Contact exists
  /// - Contact is verified
  /// - Contact has a mailbox ID
  ///
  /// This is the ENFORCED gate for all message sending.
  bool canMessage(String contactId) {
    final contact = getContact(contactId);
    if (contact == null) return false;
    if (!contact.isVerified) return false;
    if (contact.mailboxId.isEmpty) return false;
    return true;
  }

  /// Get reason why messaging is blocked.
  String? getMessagingBlockReason(String contactId) {
    final contact = getContact(contactId);
    if (contact == null) return 'Contact not found';
    if (!contact.isVerified) return 'Contact not verified - verify fingerprint first';
    if (contact.mailboxId.isEmpty) return 'Contact has no mailbox ID';
    return null;
  }

  /// Get all verified contacts only.
  List<Contact> get verifiedContacts =>
      _contacts.where((c) => c.isVerified).toList();

  /// Get all unverified contacts.
  List<Contact> get unverifiedContacts =>
      _contacts.where((c) => !c.isVerified).toList();

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
}
