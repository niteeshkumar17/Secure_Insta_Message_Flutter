/// Mailbox Client - Store-and-Forward Transport
///
/// This client communicates ONLY with mailbox servers - NEVER directly
/// with recipient devices. It treats all message content as opaque bytes.
///
/// The mailbox client:
/// - Submits sealed envelopes to mailboxes (does NOT parse them)
/// - Polls mailboxes for new envelopes (does NOT read them)
/// - Provides no response content (prevents information leakage)
///
/// Security properties:
/// - Transport sees only: mailbox_id, opaque blob, timing
/// - Transport CANNOT: identify sender, read content, correlate users

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../services/socks5_client.dart';

/// Result of a mailbox submission.
enum SubmitResult {
  /// Envelope accepted (no confirmation of delivery)
  accepted,

  /// Mailbox unreachable
  unreachable,

  /// Rate limited
  rateLimited,

  /// Invalid mailbox ID
  invalidMailbox,
}

/// Result of polling a mailbox.
class PollResult {
  /// Retrieved envelopes (opaque bytes)
  final List<List<int>> envelopes;

  /// Poll succeeded
  final bool success;

  /// Error message if failed
  final String? error;

  const PollResult({
    required this.envelopes,
    required this.success,
    this.error,
  });

  factory PollResult.success(List<List<int>> envelopes) => PollResult(
        envelopes: envelopes,
        success: true,
      );

  factory PollResult.failure(String error) => PollResult(
        envelopes: [],
        success: false,
        error: error,
      );
}

/// Mailbox server configuration.
class MailboxConfig {
  /// Onion address of the mailbox server
  final String onionAddress;

  /// Port (usually 80)
  final int port;

  const MailboxConfig({
    required this.onionAddress,
    this.port = 80,
  });
}

/// Mailbox client for store-and-forward messaging.
///
/// This is the ONLY interface between the app and the network for
/// message transport. Direct device-to-device communication is
/// explicitly forbidden.
class MailboxClient extends ChangeNotifier {
  final Socks5Client _socks5;

  /// Configured mailbox servers (multiple for redundancy)
  final List<MailboxConfig> _mailboxServers = [];

  /// Our mailbox ID (where we receive messages)
  String? _ourMailboxId;

  /// Mailbox authentication secret (prevents unauthorized polling)
  String? _authSecret;

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  MailboxClient({Socks5Client? socks5Client})
      : _socks5 = socks5Client ?? Socks5Client();

  /// Initialize with our mailbox configuration.
  Future<void> initialize({
    required String ourMailboxId,
    required String authSecret,
    required List<MailboxConfig> mailboxServers,
  }) async {
    _ourMailboxId = ourMailboxId;
    _authSecret = authSecret;
    _mailboxServers.clear();
    _mailboxServers.addAll(mailboxServers);

    _isInitialized = true;
    notifyListeners();
  }

  /// Add a mailbox server.
  void addMailboxServer(MailboxConfig config) {
    _mailboxServers.add(config);
  }

  /// Submit a sealed envelope to a mailbox.
  ///
  /// The envelope is treated as OPAQUE BYTES. This method does not
  /// and cannot parse the contents.
  ///
  /// Returns [SubmitResult.accepted] if the mailbox accepted the envelope.
  /// Note: This does NOT mean the recipient has received it - only that
  /// it's queued for delivery.
  Future<SubmitResult> submitEnvelope({
    required String mailboxId,
    required List<int> envelope,
  }) async {
    if (!_isInitialized || _mailboxServers.isEmpty) {
      return SubmitResult.unreachable;
    }

    // Try each mailbox server until success
    for (final server in _mailboxServers) {
      try {
        final response = await _socks5.post(
          server.onionAddress,
          server.port,
          '/submit',
          {
            'mailbox_id': mailboxId,
            'envelope': base64Encode(envelope),
          },
          timeout: const Duration(seconds: 60),
        );

        // We don't expect a meaningful response
        // 204 No Content or empty response = success
        // The mailbox MUST NOT return information about the envelope
        if (response != null) {
          // Any response means the server received it
          // We deliberately ignore response content
          debugPrint('MailboxClient: Envelope submitted to $mailboxId');
          return SubmitResult.accepted;
        }
      } catch (e) {
        debugPrint('MailboxClient: Failed to submit to ${server.onionAddress}: $e');
        continue; // Try next server
      }
    }

    return SubmitResult.unreachable;
  }

  /// Poll our mailbox for new envelopes.
  ///
  /// Returns sealed envelopes as OPAQUE BYTES. This method does not
  /// and cannot read the contents.
  Future<PollResult> pollMailbox() async {
    if (!_isInitialized || _ourMailboxId == null || _authSecret == null) {
      return PollResult.failure('Not initialized');
    }

    if (_mailboxServers.isEmpty) {
      return PollResult.failure('No mailbox servers configured');
    }

    // Generate authentication token
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final authToken = _generateAuthToken(timestamp);

    // Try each mailbox server
    for (final server in _mailboxServers) {
      try {
        final response = await _socks5.post(
          server.onionAddress,
          server.port,
          '/poll',
          {
            'mailbox_id': _ourMailboxId,
            'auth': authToken,
            'timestamp': timestamp,
          },
          timeout: const Duration(seconds: 30),
        );

        if (response != null && response.containsKey('envelopes')) {
          final envelopeList = response['envelopes'] as List<dynamic>? ?? [];
          final envelopes = envelopeList
              .map((e) => base64Decode(e as String))
              .toList();

          debugPrint('MailboxClient: Retrieved ${envelopes.length} envelopes');
          return PollResult.success(envelopes);
        }
      } catch (e) {
        debugPrint('MailboxClient: Failed to poll ${server.onionAddress}: $e');
        continue;
      }
    }

    return PollResult.failure('All mailbox servers unreachable');
  }

  /// Publish a prekey bundle to the mailbox.
  Future<bool> publishPrekeyBundle({
    required String bundleJson,
  }) async {
    if (!_isInitialized || _ourMailboxId == null) {
      return false;
    }

    for (final server in _mailboxServers) {
      try {
        final response = await _socks5.post(
          server.onionAddress,
          server.port,
          '/publish_bundle',
          {
            'mailbox_id': _ourMailboxId,
            'bundle': bundleJson,
          },
          timeout: const Duration(seconds: 30),
        );

        if (response != null) {
          debugPrint('MailboxClient: Published prekey bundle');
          return true;
        }
      } catch (e) {
        debugPrint('MailboxClient: Failed to publish bundle: $e');
        continue;
      }
    }

    return false;
  }

  /// Fetch a prekey bundle for a contact.
  Future<String?> fetchPrekeyBundle({
    required String contactMailboxId,
  }) async {
    if (!_isInitialized) {
      return null;
    }

    for (final server in _mailboxServers) {
      try {
        final response = await _socks5.post(
          server.onionAddress,
          server.port,
          '/fetch_bundle',
          {
            'mailbox_id': contactMailboxId,
          },
          timeout: const Duration(seconds: 30),
        );

        if (response != null && response.containsKey('bundle')) {
          return response['bundle'] as String;
        }
      } catch (e) {
        debugPrint('MailboxClient: Failed to fetch bundle: $e');
        continue;
      }
    }

    return null;
  }

  /// Generate HMAC-based authentication token.
  String _generateAuthToken(int timestamp) {
    // Simple HMAC for mailbox authentication
    // In production, use proper HMAC with crypto library
    final data = '$_ourMailboxId:$timestamp:$_authSecret';
    // Simplified - real implementation should use HMAC-SHA256
    return base64Encode(utf8.encode(data));
  }
}
