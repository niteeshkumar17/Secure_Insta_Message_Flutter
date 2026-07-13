/// Cryptographic Layer - E2E Security
///
/// This module provides cryptographic guarantees:
/// - X3DH key agreement (extended Triple Diffie-Hellman)
/// - Double Ratchet (forward secrecy, future secrecy)
/// - Sealed Sender (anonymous sender envelopes)
/// - Fixed-size padding (traffic analysis resistance)
///
/// SECURITY INVARIANT:
/// Plaintext NEVER leaves this layer except to the UI.
/// The CryptoService is the ONLY interface for message encryption/decryption.
library crypto;

export 'x3dh.dart';
export 'double_ratchet.dart';
export 'sealed_sender.dart';
export 'padding.dart';
export 'crypto_service.dart';
