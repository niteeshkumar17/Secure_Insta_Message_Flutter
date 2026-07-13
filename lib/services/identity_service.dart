import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart' as crypto_hash;
import '../models/identity.dart';
import 'core_bridge.dart';

/// Service for identity management.
///
/// Uses native Dart cryptography for Ed25519 key generation.
/// Keys are stored encrypted using flutter_secure_storage.
class IdentityService extends ChangeNotifier {
  final CoreBridge _bridge;
  final _storage = const FlutterSecureStorage();
  final _algorithm = Ed25519();

  // Store the private key in memory (encrypted storage has a copy)
  SimpleKeyPair? _keyPair;

  Identity _identity = Identity.empty();
  Identity get identity => _identity;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String? _error;
  String? get error => _error;

  IdentityService(this._bridge);

  /// Generate a new Ed25519 identity keypair.
  ///
  /// Keys are generated using Dart's cryptography package with CSPRNG.
  /// The private key is stored encrypted in secure storage.
  Future<bool> generateIdentity({required String passphrase}) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      // Generate Ed25519 keypair
      final keyPair = await _algorithm.newKeyPair();
      _keyPair = keyPair;

      // Get public key bytes
      final publicKey = await keyPair.extractPublicKey();
      final publicKeyBytes = publicKey.bytes;
      final publicKeyHex = _bytesToHex(publicKeyBytes);

      // Generate fingerprint (SHA-256 of public key, first 16 bytes as hex)
      final fingerprintBytes = crypto_hash.sha256.convert(publicKeyBytes).bytes;
      final fingerprint = _bytesToHex(fingerprintBytes.sublist(0, 16));

      // Store private key encrypted (flutter_secure_storage handles encryption)
      final privateKeyBytes = await keyPair.extractPrivateKeyBytes();
      final privateKeyHex = _bytesToHex(privateKeyBytes);
      
      // Generate random 32-byte mailbox ID
      final random = Random.secure();
      final mailboxIdBytes = List<int>.generate(32, (_) => random.nextInt(256));
      final mailboxId = _bytesToHex(mailboxIdBytes);
      
      // Store with passphrase as additional verification
      final passphraseHash = crypto_hash.sha256.convert(utf8.encode(passphrase)).toString();
      await _storage.write(key: 'identity_private_key', value: privateKeyHex);
      await _storage.write(key: 'identity_public_key', value: publicKeyHex);
      await _storage.write(key: 'identity_fingerprint', value: fingerprint);
      await _storage.write(key: 'identity_mailbox_id', value: mailboxId);
      await _storage.write(key: 'identity_passphrase_hash', value: passphraseHash);

      _identity = Identity(
        fingerprint: fingerprint,
        publicKey: publicKeyHex,
        onionAddress: null, // Will be generated when Tor hidden service starts
        mailboxId: mailboxId,
        isLoaded: true,
      );

      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Failed to generate identity: $e';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// Load an existing identity from the encrypted keystore.
  Future<bool> loadIdentity({required String passphrase}) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      // Verify passphrase
      final storedHash = await _storage.read(key: 'identity_passphrase_hash');
      final providedHash = crypto_hash.sha256.convert(utf8.encode(passphrase)).toString();
      
      if (storedHash != providedHash) {
        _error = 'Invalid passphrase';
        _isLoading = false;
        notifyListeners();
        return false;
      }

      // Load keys
      final privateKeyHex = await _storage.read(key: 'identity_private_key');
      final publicKeyHex = await _storage.read(key: 'identity_public_key');
      final fingerprint = await _storage.read(key: 'identity_fingerprint');
      var mailboxId = await _storage.read(key: 'identity_mailbox_id');

      if (privateKeyHex == null || publicKeyHex == null || fingerprint == null) {
        _error = 'No stored identity found';
        _isLoading = false;
        notifyListeners();
        return false;
      }
      
      // Generate mailbox_id if not present (for existing identities)
      if (mailboxId == null) {
        final random = Random.secure();
        final mailboxIdBytes = List<int>.generate(32, (_) => random.nextInt(256));
        mailboxId = _bytesToHex(mailboxIdBytes);
        await _storage.write(key: 'identity_mailbox_id', value: mailboxId);
      }

      // Reconstruct keypair
      final privateKeyBytes = _hexToBytes(privateKeyHex);
      final publicKeyBytes = _hexToBytes(publicKeyHex);
      
      _keyPair = SimpleKeyPairData(
        privateKeyBytes,
        publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
        type: KeyPairType.ed25519,
      );

      _identity = Identity(
        fingerprint: fingerprint,
        publicKey: publicKeyHex,
        onionAddress: null,
        mailboxId: mailboxId,
        isLoaded: true,
      );

      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Failed to load identity: $e';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// Update the onion address once Tor hidden service is ready.
  void updateOnionAddress(String? onionAddress) {
    if (_identity.isLoaded && onionAddress != null && onionAddress.isNotEmpty) {
      _identity = Identity(
        fingerprint: _identity.fingerprint,
        publicKey: _identity.publicKey,
        onionAddress: onionAddress,
        mailboxId: _identity.mailboxId,
        isLoaded: true,
      );
      notifyListeners();
    }
  }

  /// Export identity data for sharing (public key only).
  Future<String?> exportIdentity() async {
    if (!_identity.isLoaded) {
      _error = 'No identity loaded';
      notifyListeners();
      return null;
    }

    // Export as JSON with public key, fingerprint, onion address, and mailbox ID
    final exportData = jsonEncode({
      'public_key': _identity.publicKey,
      'fingerprint': _identity.fingerprint,
      'onion_address': _identity.onionAddress,
      'mailbox_id': _identity.mailboxId,
    });

    return base64Encode(utf8.encode(exportData));
  }

  /// Import an identity from exported data (contact's public key).
  Future<bool> importIdentity({
    required String importData,
    required String passphrase,
  }) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      // Decode the import data
      final jsonStr = utf8.decode(base64Decode(importData));
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;

      // This imports a contact's identity, not replaces our own
      // For now, just validate the data format
      final publicKey = data['public_key'] as String?;
      final fingerprint = data['fingerprint'] as String?;

      if (publicKey == null || fingerprint == null) {
        _error = 'Invalid import data format';
        _isLoading = false;
        notifyListeners();
        return false;
      }

      // Successfully parsed - in a full implementation this would add as contact
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Failed to import identity: $e';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// Get the current keypair for signing operations.
  SimpleKeyPair? get keyPair => _keyPair;

  /// Sign data with the private key.
  Future<List<int>?> sign(List<int> data) async {
    if (_keyPair == null) return null;
    final signature = await _algorithm.sign(data, keyPair: _keyPair!);
    return signature.bytes;
  }

  /// Verify a signature.
  Future<bool> verify(List<int> data, List<int> signatureBytes, List<int> publicKeyBytes) async {
    try {
      final publicKey = SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519);
      final signature = Signature(signatureBytes, publicKey: publicKey);
      return await _algorithm.verify(data, signature: signature);
    } catch (e) {
      return false;
    }
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
}

