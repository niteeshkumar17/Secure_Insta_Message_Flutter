/// Contact model — presentation only.
///
/// Trust is established manually by the user verifying fingerprints.
/// No automatic trust, no TOFU, no server-mediated trust.
class Contact {
  /// Unique identifier for this contact (local only).
  final String id;

  /// User-assigned label / alias.
  final String label;

  /// The contact's public key (hex-encoded).
  final String publicKey;

  /// The contact's Ed25519 fingerprint.
  final String fingerprint;

  /// The contact's .onion address for routing messages.
  final String onionAddress;

  /// The mailbox ID for this contact (hex-encoded).
  final String mailboxId;

  /// Whether the user has manually verified this contact's fingerprint.
  final bool isVerified;

  /// Whether a session (Double Ratchet) has been established.
  final bool hasSession;

  const Contact({
    required this.id,
    required this.label,
    required this.publicKey,
    required this.fingerprint,
    required this.onionAddress,
    required this.mailboxId,
    this.isVerified = false,
    this.hasSession = false,
  });

  factory Contact.fromJson(Map<String, dynamic> json) => Contact(
        id: json['id'] as String? ?? '',
        label: json['label'] as String? ?? '',
        publicKey: json['public_key'] as String? ?? '',
        fingerprint: json['fingerprint'] as String? ?? '',
        onionAddress: json['onion_address'] as String? ?? '',
        mailboxId: json['mailbox_id'] as String? ?? '',
        isVerified: json['is_verified'] as bool? ?? false,
        hasSession: json['has_session'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'public_key': publicKey,
        'fingerprint': fingerprint,
        'onion_address': onionAddress,
        'mailbox_id': mailboxId,
        'is_verified': isVerified,
        'has_session': hasSession,
      };

  Contact copyWith({
    String? label,
    bool? isVerified,
    bool? hasSession,
  }) =>
      Contact(
        id: id,
        label: label ?? this.label,
        publicKey: publicKey,
        fingerprint: fingerprint,
        onionAddress: onionAddress,
        mailboxId: mailboxId,
        isVerified: isVerified ?? this.isVerified,
        hasSession: hasSession ?? this.hasSession,
      );

  /// Format fingerprint for display.
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

