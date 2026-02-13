import 'package:flutter/foundation.dart';
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
class ContactsService extends ChangeNotifier {
  final CoreBridge _bridge;

  List<Contact> _contacts = [];
  List<Contact> get contacts => List.unmodifiable(_contacts);

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String? _error;
  String? get error => _error;

  ContactsService(this._bridge);

  /// Load all contacts from the core's encrypted storage.
  Future<void> loadContacts() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    final response = await _bridge.send(method: 'list_contacts');

    _isLoading = false;

    if (response.success && response.result != null) {
      final list = response.result!['contacts'] as List<dynamic>?;
      _contacts = list
              ?.map((c) =>
                  Contact.fromJson(c as Map<String, dynamic>))
              .toList() ??
          [];
    } else {
      _error = response.error ?? 'Failed to load contacts';
    }

    notifyListeners();
  }

  /// Add a contact manually by their public key and onion address.
  Future<bool> addContact({
    required String label,
    required String publicKey,
    required String onionAddress,
    required String mailboxId,
  }) async {
    _error = null;

    final response = await _bridge.send(
      method: 'add_contact',
      params: {
        'label': label,
        'public_key': publicKey,
        'onion_address': onionAddress,
        'mailbox_id': mailboxId,
      },
    );

    if (response.success && response.result != null) {
      final contact =
          Contact.fromJson(response.result!);
      _contacts.add(contact);
      notifyListeners();
      return true;
    }

    _error = response.error ?? 'Failed to add contact';
    notifyListeners();
    return false;
  }

  /// Remove a contact.
  Future<bool> removeContact(String contactId) async {
    final response = await _bridge.send(
      method: 'remove_contact',
      params: {'contact_id': contactId},
    );

    if (response.success) {
      _contacts.removeWhere((c) => c.id == contactId);
      notifyListeners();
      return true;
    }

    _error = response.error ?? 'Failed to remove contact';
    notifyListeners();
    return false;
  }

  /// Mark a contact as manually verified.
  ///
  /// The user must verify the fingerprint out-of-band (in person,
  /// secure channel, etc). The app does not verify automatically.
  Future<bool> verifyContact(String contactId) async {
    final response = await _bridge.send(
      method: 'verify_contact',
      params: {'contact_id': contactId},
    );

    if (response.success) {
      final index = _contacts.indexWhere((c) => c.id == contactId);
      if (index >= 0) {
        _contacts[index] = _contacts[index].copyWith(isVerified: true);
        notifyListeners();
      }
      return true;
    }

    _error = response.error ?? 'Failed to verify contact';
    notifyListeners();
    return false;
  }

  /// Get a specific contact by ID.
  Contact? getContact(String contactId) {
    try {
      return _contacts.firstWhere((c) => c.id == contactId);
    } catch (_) {
      return null;
    }
  }
}

