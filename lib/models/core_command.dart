import 'dart:convert';

/// A command sent from Flutter to the Python core via JSON-RPC.
///
/// The Flutter client ONLY sends commands — it never performs
/// any protocol logic itself.
class CoreCommand {
  /// Unique request ID for correlating responses.
  final String id;

  /// The method name (e.g., 'generate_identity', 'send_message').
  final String method;

  /// Parameters for the method.
  final Map<String, dynamic> params;

  const CoreCommand({
    required this.id,
    required this.method,
    this.params = const {},
  });

  /// Available core commands:
  ///
  /// Identity:
  ///   - generate_identity         Generate a new Ed25519 keypair
  ///   - load_identity             Load identity from encrypted keystore
  ///   - export_identity           Export identity for sharing
  ///   - import_identity           Import identity from data
  ///
  /// Contacts:
  ///   - add_contact               Add a contact by public key + onion
  ///   - remove_contact            Remove a contact
  ///   - list_contacts             List all contacts
  ///   - verify_contact            Mark a contact as verified
  ///
  /// Messaging:
  ///   - send_message              Send a text message
  ///   - send_voice_message        Send a voice message
  ///   - poll_mailbox              Check for new messages
  ///   - get_messages              Get message history for a contact
  ///
  /// Network:
  ///   - get_network_status        Get Tor / relay / cover status
  ///   - configure_relay           Set relay preferences
  ///   - configure_mailbox         Set mailbox address

  String toJsonString() => jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      });
}

