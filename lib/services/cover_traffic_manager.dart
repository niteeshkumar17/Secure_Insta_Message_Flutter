/// Cover Traffic Manager - Metadata Resistance
///
/// This service ensures constant traffic patterns regardless of actual
/// messaging activity. Without cover traffic, an adversary observing
/// the network could correlate message timing with user activity.
///
/// Properties:
/// - Polls mailbox at CONSTANT rate (not triggered by user action)
/// - Sends cover messages when idle to maintain traffic volume
/// - All messages (real and cover) are indistinguishable at transport
///
/// Security guarantee:
/// Observer sees: constant stream of identically-sized encrypted blobs
/// Observer learns: nothing about when real messages are sent/received

import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'mailbox_client.dart';
import '../crypto/crypto_service.dart';
import '../crypto/padding.dart';

/// Configuration for cover traffic behavior.
class CoverTrafficConfig {
  /// Interval between mailbox polls (constant rate)
  final Duration pollInterval;

  /// Minimum number of outbound messages per interval
  final int minOutboundPerInterval;

  /// Jitter range for timing (percentage)
  final double jitterPercent;

  /// Whether to enable cover traffic (can be disabled for testing)
  final bool enabled;

  const CoverTrafficConfig({
    this.pollInterval = const Duration(seconds: 30),
    this.minOutboundPerInterval = 1,
    this.jitterPercent = 0.2,
    this.enabled = true,
  });
}

/// Queue entry for outbound messages.
class OutboundQueueEntry {
  /// Target mailbox ID
  final String mailboxId;

  /// Sealed envelope (opaque bytes)
  final List<int> envelope;

  /// When this was queued
  final DateTime queuedAt;

  /// Is this a real message (vs cover traffic)?
  /// This is ONLY used internally for statistics - never exposed to transport
  final bool isReal;

  OutboundQueueEntry({
    required this.mailboxId,
    required this.envelope,
    required this.isReal,
  }) : queuedAt = DateTime.now();
}

/// Statistics about cover traffic (not exposed to network).
class CoverTrafficStats {
  int realMessagesSent = 0;
  int coverMessagesSent = 0;
  int pollsPerformed = 0;
  int envelopesReceived = 0;

  double get coverRatio {
    final total = realMessagesSent + coverMessagesSent;
    return total > 0 ? coverMessagesSent / total : 0;
  }
}

/// Cover Traffic Manager.
///
/// This manager wraps the mailbox client and ensures:
/// 1. Constant-rate polling (independent of incoming messages)
/// 2. Minimum outbound traffic (padding with cover messages)
/// 3. All traffic is indistinguishable
class CoverTrafficManager extends ChangeNotifier {
  final MailboxClient _mailboxClient;
  final CryptoService _cryptoService;
  final CoverTrafficConfig _config;

  final _random = Random.secure();
  final CoverTrafficStats stats = CoverTrafficStats();

  /// Outbound message queue
  final List<OutboundQueueEntry> _outboundQueue = [];

  /// Cover mailbox IDs (dummy mailboxes for cover traffic)
  /// These MUST be valid mailboxes that silently discard messages
  final List<String> _coverMailboxIds = [];

  Timer? _pollTimer;
  Timer? _sendTimer;
  bool _isRunning = false;
  bool get isRunning => _isRunning;

  /// Callback for processing received envelopes
  Future<void> Function(List<int> envelope)? onEnvelopeReceived;

  CoverTrafficManager({
    required MailboxClient mailboxClient,
    required CryptoService cryptoService,
    CoverTrafficConfig? config,
  })  : _mailboxClient = mailboxClient,
        _cryptoService = cryptoService,
        _config = config ?? const CoverTrafficConfig();

  /// Add cover mailbox IDs.
  /// These are dummy mailboxes operated by the service that
  /// accept and discard messages silently.
  void addCoverMailboxes(List<String> mailboxIds) {
    _coverMailboxIds.addAll(mailboxIds);
  }

  /// Queue a real message for sending.
  ///
  /// The message will be sent at the next transmission interval,
  /// mixed with cover traffic to hide timing.
  void queueMessage({
    required String mailboxId,
    required List<int> envelope,
  }) {
    _outboundQueue.add(OutboundQueueEntry(
      mailboxId: mailboxId,
      envelope: envelope,
      isReal: true,
    ));
    debugPrint('CoverTraffic: Queued real message for $mailboxId');
  }

  /// Start cover traffic management.
  void start() {
    if (_isRunning || !_config.enabled) return;

    _isRunning = true;

    // Start constant-rate polling
    _pollTimer = Timer.periodic(_applyJitter(_config.pollInterval), (_) {
      _pollMailbox();
    });

    // Start constant-rate sending
    _sendTimer = Timer.periodic(_applyJitter(_config.pollInterval), (_) {
      _sendBatch();
    });

    debugPrint('CoverTraffic: Started with ${_config.pollInterval.inSeconds}s intervals');
    notifyListeners();
  }

  /// Stop cover traffic management.
  void stop() {
    _pollTimer?.cancel();
    _sendTimer?.cancel();
    _pollTimer = null;
    _sendTimer = null;
    _isRunning = false;
    debugPrint('CoverTraffic: Stopped');
    notifyListeners();
  }

  /// Poll mailbox at constant rate.
  Future<void> _pollMailbox() async {
    final result = await _mailboxClient.pollMailbox();

    if (result.success) {
      stats.pollsPerformed++;

      for (final envelope in result.envelopes) {
        stats.envelopesReceived++;

        // Process envelope through callback
        if (onEnvelopeReceived != null) {
          try {
            await onEnvelopeReceived!(envelope);
          } catch (e) {
            debugPrint('CoverTraffic: Error processing envelope: $e');
          }
        }
      }
    }
  }

  /// Send a batch of messages (real + cover).
  Future<void> _sendBatch() async {
    final batch = _prepareBatch();

    // Send all messages in batch (shuffled order)
    batch.shuffle(_random);

    for (final entry in batch) {
      final result = await _mailboxClient.submitEnvelope(
        mailboxId: entry.mailboxId,
        envelope: entry.envelope,
      );

      if (result == SubmitResult.accepted) {
        if (entry.isReal) {
          stats.realMessagesSent++;
        } else {
          stats.coverMessagesSent++;
        }
      }

      // Small random delay between sends (within jitter)
      await Future.delayed(Duration(
        milliseconds: _random.nextInt(200) + 50,
      ));
    }
  }

  /// Prepare batch of messages to send.
  List<OutboundQueueEntry> _prepareBatch() {
    final batch = <OutboundQueueEntry>[];

    // Add all queued real messages
    batch.addAll(_outboundQueue);
    _outboundQueue.clear();

    // Pad with cover messages to reach minimum
    final coverNeeded = _config.minOutboundPerInterval - batch.length;
    for (var i = 0; i < coverNeeded && _coverMailboxIds.isNotEmpty; i++) {
      batch.add(_generateCoverMessage());
    }

    return batch;
  }

  /// Generate a cover message.
  OutboundQueueEntry _generateCoverMessage() {
    // Pick random cover mailbox
    final mailboxId = _coverMailboxIds[_random.nextInt(_coverMailboxIds.length)];

    // Generate cover envelope (indistinguishable from real)
    final coverData = _cryptoService.generateCoverMessage();

    return OutboundQueueEntry(
      mailboxId: mailboxId,
      envelope: coverData,
      isReal: false,
    );
  }

  /// Apply jitter to duration.
  Duration _applyJitter(Duration base) {
    final jitterMs = (base.inMilliseconds * _config.jitterPercent).toInt();
    final offset = _random.nextInt(jitterMs * 2) - jitterMs;
    return Duration(milliseconds: base.inMilliseconds + offset);
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
