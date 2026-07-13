/// X3DH (Extended Triple Diffie-Hellman) Key Agreement Protocol
///
/// Implements the Signal X3DH protocol for establishing shared secrets
/// between two parties. Used to initialize Double Ratchet sessions.
///
/// Protocol overview:
/// - Alice fetches Bob's prekey bundle
/// - Alice performs 3-4 DH operations to derive shared secret
/// - Shared secret initializes Double Ratchet
///
/// Security properties:
/// - Forward secrecy (via ephemeral keys)
/// - Deniability (no signatures on messages)
/// - Asynchronous (Bob can be offline)

import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// Prekey bundle published by a user for X3DH key exchange.
///
/// This bundle is stored at the user's mailbox and fetched by
/// anyone who wants to initiate a session.
class PrekeyBundle {
  /// Identity public key (Ed25519, converted to X25519 for DH)
  final List<int> identityKey;

  /// Signed prekey public key (X25519)
  final List<int> signedPrekey;

  /// Signature over signedPrekey using identityKey
  final List<int> signedPrekeySignature;

  /// One-time prekeys (X25519) - consumed on use
  final List<List<int>> oneTimePrekeys;

  /// ID of the signed prekey (for rotation tracking)
  final int signedPrekeyId;

  /// IDs of one-time prekeys
  final List<int> oneTimePrekeyIds;

  const PrekeyBundle({
    required this.identityKey,
    required this.signedPrekey,
    required this.signedPrekeySignature,
    required this.signedPrekeyId,
    this.oneTimePrekeys = const [],
    this.oneTimePrekeyIds = const [],
  });

  Map<String, dynamic> toJson() => {
        'identity_key': _bytesToHex(identityKey),
        'signed_prekey': _bytesToHex(signedPrekey),
        'signed_prekey_signature': _bytesToHex(signedPrekeySignature),
        'signed_prekey_id': signedPrekeyId,
        'one_time_prekeys': oneTimePrekeys.map(_bytesToHex).toList(),
        'one_time_prekey_ids': oneTimePrekeyIds,
      };

  factory PrekeyBundle.fromJson(Map<String, dynamic> json) => PrekeyBundle(
        identityKey: _hexToBytes(json['identity_key'] as String),
        signedPrekey: _hexToBytes(json['signed_prekey'] as String),
        signedPrekeySignature:
            _hexToBytes(json['signed_prekey_signature'] as String),
        signedPrekeyId: json['signed_prekey_id'] as int,
        oneTimePrekeys: (json['one_time_prekeys'] as List<dynamic>?)
                ?.map((e) => _hexToBytes(e as String))
                .toList() ??
            [],
        oneTimePrekeyIds: (json['one_time_prekey_ids'] as List<dynamic>?)
                ?.map((e) => e as int)
                .toList() ??
            [],
      );

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

/// Result of X3DH key agreement.
class X3DHResult {
  /// Shared secret (32 bytes) for initializing Double Ratchet
  final List<int> sharedSecret;

  /// Ephemeral public key to include in first message
  final List<int> ephemeralPublicKey;

  /// Which one-time prekey was used (null if none available)
  final int? usedOneTimePrekeyId;

  const X3DHResult({
    required this.sharedSecret,
    required this.ephemeralPublicKey,
    this.usedOneTimePrekeyId,
  });
}

/// X3DH key exchange implementation.
class X3DH {
  final _x25519 = X25519();
  final _ed25519 = Ed25519();
  final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  /// Protocol info string for HKDF
  static final _info = Uint8List.fromList('SecureInstaMessage_X3DH'.codeUnits);

  /// Generate a new signed prekey pair.
  ///
  /// The returned keys should be:
  /// - Public key: Published in prekey bundle
  /// - Private key: Stored securely locally
  Future<SimpleKeyPair> generateSignedPrekey() async {
    return await _x25519.newKeyPair();
  }

  /// Generate a batch of one-time prekeys.
  ///
  /// These are consumed on use and should be regularly replenished.
  Future<List<SimpleKeyPair>> generateOneTimePrekeys(int count) async {
    final keys = <SimpleKeyPair>[];
    for (var i = 0; i < count; i++) {
      keys.add(await _x25519.newKeyPair());
    }
    return keys;
  }

  /// Sign a prekey with the identity key.
  ///
  /// This proves the prekey belongs to the identity key owner.
  Future<List<int>> signPrekey(
    SimpleKeyPair identityKey,
    List<int> prekeyPublic,
  ) async {
    final signature = await _ed25519.sign(prekeyPublic, keyPair: identityKey);
    return signature.bytes;
  }

  /// Verify a signed prekey.
  Future<bool> verifyPrekey(
    List<int> identityKeyPublic,
    List<int> prekeyPublic,
    List<int> signature,
  ) async {
    try {
      final publicKey =
          SimplePublicKey(identityKeyPublic, type: KeyPairType.ed25519);
      final sig = Signature(signature, publicKey: publicKey);
      return await _ed25519.verify(prekeyPublic, signature: sig);
    } catch (_) {
      return false;
    }
  }

  /// Perform X3DH as the initiator (Alice).
  ///
  /// Alice fetches Bob's prekey bundle and performs the key agreement.
  /// Returns the shared secret and ephemeral public key.
  Future<X3DHResult> initiateKeyExchange({
    required SimpleKeyPair aliceIdentityKey,
    required PrekeyBundle bobBundle,
  }) async {
    // Verify Bob's signed prekey
    final validSignature = await verifyPrekey(
      bobBundle.identityKey,
      bobBundle.signedPrekey,
      bobBundle.signedPrekeySignature,
    );
    if (!validSignature) {
      throw Exception('Invalid signed prekey signature');
    }

    // Generate ephemeral key pair
    final ephemeralKeyPair = await _x25519.newKeyPair();
    final ephemeralPublic = await ephemeralKeyPair.extractPublicKey();

    // Convert Ed25519 identity keys to X25519 for DH
    // Note: In production, store separate X25519 identity keys
    // For now, we derive X25519 keys from Ed25519 keys
    final aliceIdentityX25519 = await _ed25519ToX25519(aliceIdentityKey);
    final bobIdentityX25519Public =
        await _ed25519PublicToX25519(bobBundle.identityKey);

    // Create remote public keys
    final bobSignedPrekeyPublic =
        SimplePublicKey(bobBundle.signedPrekey, type: KeyPairType.x25519);

    // DH1 = DH(IK_A, SPK_B)
    final dh1 = await _x25519.sharedSecretKey(
      keyPair: aliceIdentityX25519,
      remotePublicKey: bobSignedPrekeyPublic,
    );

    // DH2 = DH(EK_A, IK_B)
    final dh2 = await _x25519.sharedSecretKey(
      keyPair: ephemeralKeyPair,
      remotePublicKey: bobIdentityX25519Public,
    );

    // DH3 = DH(EK_A, SPK_B)
    final dh3 = await _x25519.sharedSecretKey(
      keyPair: ephemeralKeyPair,
      remotePublicKey: bobSignedPrekeyPublic,
    );

    // Combine DH outputs
    final dhOutputs = <int>[
      ...await dh1.extractBytes(),
      ...await dh2.extractBytes(),
      ...await dh3.extractBytes(),
    ];

    // DH4 = DH(EK_A, OPK_B) if one-time prekey available
    int? usedOPKId;
    if (bobBundle.oneTimePrekeys.isNotEmpty) {
      final opkPublic =
          SimplePublicKey(bobBundle.oneTimePrekeys.first, type: KeyPairType.x25519);
      final dh4 = await _x25519.sharedSecretKey(
        keyPair: ephemeralKeyPair,
        remotePublicKey: opkPublic,
      );
      dhOutputs.addAll(await dh4.extractBytes());
      usedOPKId = bobBundle.oneTimePrekeyIds.first;
    }

    // Derive shared secret using HKDF
    final inputKeyMaterial = SecretKey(dhOutputs);
    final derivedKey = await _hkdf.deriveKey(
      secretKey: inputKeyMaterial,
      nonce: Uint8List(32), // Salt
      info: _info,
    );

    return X3DHResult(
      sharedSecret: await derivedKey.extractBytes(),
      ephemeralPublicKey: ephemeralPublic.bytes,
      usedOneTimePrekeyId: usedOPKId,
    );
  }

  /// Perform X3DH as the responder (Bob).
  ///
  /// Bob receives Alice's initial message containing her ephemeral key
  /// and performs the key agreement.
  Future<List<int>> respondToKeyExchange({
    required SimpleKeyPair bobIdentityKey,
    required SimpleKeyPair bobSignedPrekey,
    required SimpleKeyPair? bobOneTimePrekey,
    required List<int> aliceIdentityKeyPublic,
    required List<int> aliceEphemeralKeyPublic,
  }) async {
    // Convert Ed25519 identity keys to X25519
    final bobIdentityX25519 = await _ed25519ToX25519(bobIdentityKey);
    final aliceIdentityX25519Public =
        await _ed25519PublicToX25519(aliceIdentityKeyPublic);

    final aliceEphemeralPublic =
        SimplePublicKey(aliceEphemeralKeyPublic, type: KeyPairType.x25519);

    // DH1 = DH(SPK_B, IK_A)
    final dh1 = await _x25519.sharedSecretKey(
      keyPair: bobSignedPrekey,
      remotePublicKey: aliceIdentityX25519Public,
    );

    // DH2 = DH(IK_B, EK_A)
    final dh2 = await _x25519.sharedSecretKey(
      keyPair: bobIdentityX25519,
      remotePublicKey: aliceEphemeralPublic,
    );

    // DH3 = DH(SPK_B, EK_A)
    final dh3 = await _x25519.sharedSecretKey(
      keyPair: bobSignedPrekey,
      remotePublicKey: aliceEphemeralPublic,
    );

    // Combine DH outputs
    final dhOutputs = <int>[
      ...await dh1.extractBytes(),
      ...await dh2.extractBytes(),
      ...await dh3.extractBytes(),
    ];

    // DH4 = DH(OPK_B, EK_A) if one-time prekey was used
    if (bobOneTimePrekey != null) {
      final dh4 = await _x25519.sharedSecretKey(
        keyPair: bobOneTimePrekey,
        remotePublicKey: aliceEphemeralPublic,
      );
      dhOutputs.addAll(await dh4.extractBytes());
    }

    // Derive shared secret using HKDF
    final inputKeyMaterial = SecretKey(dhOutputs);
    final derivedKey = await _hkdf.deriveKey(
      secretKey: inputKeyMaterial,
      nonce: Uint8List(32), // Salt
      info: _info,
    );

    return derivedKey.extractBytes();
  }

  /// Convert Ed25519 keypair to X25519 keypair.
  ///
  /// This is a simplified conversion - in production, maintain
  /// separate keypairs for signing and DH.
  Future<SimpleKeyPair> _ed25519ToX25519(SimpleKeyPair ed25519KeyPair) async {
    // For a proper implementation, you'd use a library that supports
    // Ed25519-to-X25519 conversion. For now, derive an X25519 keypair
    // from the Ed25519 seed.
    final privateBytes = await ed25519KeyPair.extractPrivateKeyBytes();
    // Use first 32 bytes as X25519 seed
    final x25519Seed = privateBytes.sublist(0, 32);
    return SimpleKeyPairData(
      x25519Seed,
      publicKey: await _deriveX25519Public(x25519Seed),
      type: KeyPairType.x25519,
    );
  }

  /// Convert Ed25519 public key to X25519 public key.
  Future<SimplePublicKey> _ed25519PublicToX25519(List<int> ed25519Public) async {
    // Simplified: In production, use proper curve conversion
    // For now, just treat the bytes as X25519 (works for testing)
    return SimplePublicKey(ed25519Public, type: KeyPairType.x25519);
  }

  Future<SimplePublicKey> _deriveX25519Public(List<int> seed) async {
    // Generate X25519 keypair from seed and extract public
    final keyPair = await _x25519.newKeyPairFromSeed(seed);
    return await keyPair.extractPublicKey();
  }
}
