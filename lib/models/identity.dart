/// Identity model — presentation only.
///
/// The actual Ed25519 key material never leaves the Python core.
/// This model holds only what the UI needs to display.
class Identity {
  /// The Ed25519 public key fingerprint (hex-encoded).
  final String fingerprint;

  /// The full public key (hex-encoded), used for sharing.
  final String publicKey;

  /// The .onion address for receiving messages.
  final String? onionAddress;

  /// Whether the identity has been loaded from the keystore.
  final bool isLoaded;

  const Identity({
    required this.fingerprint,
    required this.publicKey,
    this.onionAddress,
    this.isLoaded = false,
  });

  factory Identity.empty() => const Identity(
        fingerprint: '',
        publicKey: '',
        isLoaded: false,
      );

  factory Identity.fromJson(Map<String, dynamic> json) => Identity(
        fingerprint: json['fingerprint'] as String? ?? '',
        publicKey: json['public_key'] as String? ?? '',
        onionAddress: json['onion_address'] as String?,
        isLoaded: json['is_loaded'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'fingerprint': fingerprint,
        'public_key': publicKey,
        'onion_address': onionAddress,
        'is_loaded': isLoaded,
      };

  /// Format fingerprint in groups of 4 for readability.
  String get formattedFingerprint {
    if (fingerprint.isEmpty) return '';
    final buffer = StringBuffer();
    for (var i = 0; i < fingerprint.length; i += 4) {
      if (i > 0) buffer.write(' ');
      final end =
          (i + 4 > fingerprint.length) ? fingerprint.length : i + 4;
      buffer.write(fingerprint.substring(i, end));
    }
    return buffer.toString().toUpperCase();
  }
}

