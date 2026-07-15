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
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'mailbox_client.dart';
import '../crypto/crypto_service.dart';

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
    this.pollInterval = const Duration(seconds: 1),
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
class CoverTrafficManager extends ChangeNotifier with WidgetsBindingObserver {
  final MailboxClient _mailboxClient;
  final CryptoService _cryptoService;
  final CoverTrafficConfig _config;
  final _storage = const FlutterSecureStorage();

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
  bool _isSending = false;
  bool _isPolling = false;

  Timer? _debounceTimer;
  bool _hasPendingSave = false;
  bool _isSavingQueue = false;

  /// Callback for processing received envelopes
  Future<void> Function(List<int> envelope)? onEnvelopeReceived;

  CoverTrafficManager({
    required MailboxClient mailboxClient,
    required CryptoService cryptoService,
    CoverTrafficConfig? config,
  })  : _mailboxClient = mailboxClient,
        _cryptoService = cryptoService,
        _config = config ?? const CoverTrafficConfig() {
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      flushQueue();
    }
  }

  void _scheduleSaveQueue() {
    _hasPendingSave = true;
    if (_debounceTimer?.isActive ?? false) return;

    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      flushQueue();
    });
  }

  Future<void> flushQueue() async {
    if (!_hasPendingSave) return;
    if (_isSavingQueue) {
      _debounceTimer?.cancel();
      _debounceTimer = Timer(const Duration(milliseconds: 100), () {
        flushQueue();
      });
      return;
    }

    _isSavingQueue = true;
    _hasPendingSave = false;
    _debounceTimer?.cancel();

    try {
      await _saveQueue();
    } finally {
      _isSavingQueue = false;
    }
  }

  Future<void> _saveQueue() async {
    try {
      final List<Map<String, dynamic>> queueJson = _outboundQueue.where((e) => e.isReal).map((entry) => {
        'mailbox_id': entry.mailboxId,
        'envelope': _bytesToHex(entry.envelope),
      }).toList();
      await _storage.write(key: 'cover_traffic_outbound_queue_v1', value: json.encode(queueJson));
    } catch (e) {
      debugPrint('CoverTrafficManager: Error saving queue: $e');
    }
  }

  Future<void> loadQueue() async {
    try {
      final queueStr = await _storage.read(key: 'cover_traffic_outbound_queue_v1');
      if (queueStr != null) {
        final List<dynamic> decoded = json.decode(queueStr);
        _outboundQueue.clear();
        for (final item in decoded) {
          final mailboxId = item['mailbox_id'] as String;
          final envelopeHex = item['envelope'] as String;
          _outboundQueue.add(OutboundQueueEntry(
            mailboxId: mailboxId,
            envelope: _hexToBytes(envelopeHex),
            isReal: true,
          ));
        }
        debugPrint('CoverTrafficManager: Loaded ${_outboundQueue.length} real messages from queue persistence.');
      }
    } catch (e) {
      debugPrint('CoverTrafficManager: Error loading queue: $e');
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
    _scheduleSaveQueue();
    debugPrint('CoverTraffic: Queued real message for $mailboxId');
  }

  /// Start cover traffic management.
  void start() async {
    if (_isRunning || !_config.enabled) return;

    if (_coverMailboxIds.isEmpty) {
      for (var i = 0; i < 5; i++) {
        final randomId = List.generate(32, (_) => _random.nextInt(16).toRadixString(16)).join();
        _coverMailboxIds.add(randomId);
      }
    }

    // Load persisted real messages from storage queue
    await loadQueue();

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

  /// Callback when the server requests a new prekey bundle
  Future<void> Function()? onNeedsBundle;

  Future<void> _pollMailbox() async {
    if (_isPolling) return;
    _isPolling = true;

    try {
      final result = await _mailboxClient.pollMailbox();

      if (result.success) {
        stats.pollsPerformed++;

        if (result.needsBundle && onNeedsBundle != null) {
          debugPrint('CoverTraffic: Server requested new bundle, calling callback');
          try {
            await onNeedsBundle!();
          } catch (e) {
            debugPrint('CoverTraffic: onNeedsBundle callback failed: $e');
          }
        }

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
    } finally {
      _isPolling = false;
    }
  }

  Future<void> _sendBatch() async {
    if (_isSending) return;
    _isSending = true;

    try {
      // Copy the current real messages queue to send
      final realMessages = List<OutboundQueueEntry>.from(_outboundQueue);

      // Pad with cover messages to reach the configured minimum
      final coverMessages = <OutboundQueueEntry>[];
      final coverNeeded = _config.minOutboundPerInterval - realMessages.length;
      for (var i = 0; i < coverNeeded && _coverMailboxIds.isNotEmpty; i++) {
        coverMessages.add(_generateCoverMessage());
      }

      // Interleave real and cover messages randomly to obscure actual activity
      final finalBatch = List<OutboundQueueEntry>.from(realMessages);
      for (final cover in coverMessages) {
        final insertPos = _random.nextInt(finalBatch.length + 1);
        finalBatch.insert(insertPos, cover);
      }

      for (final entry in finalBatch) {
        final result = await _mailboxClient.submitEnvelope(
          mailboxId: entry.mailboxId,
          envelope: entry.envelope,
        );

        if (result == SubmitResult.accepted) {
          if (entry.isReal) {
            stats.realMessagesSent++;
            // Transactional: remove from list and save to secure storage only on success
            _outboundQueue.removeWhere((e) => e.mailboxId == entry.mailboxId && _listEquals(e.envelope, entry.envelope));
            _scheduleSaveQueue();
          } else {
            stats.coverMessagesSent++;
          }
        } else {
          if (entry.isReal) {
            debugPrint('CoverTraffic: Failed to submit real envelope to ${entry.mailboxId}, keeping in queue.');
          }
        }

        // Small random delay between sends (within jitter)
        await Future.delayed(Duration(
          milliseconds: _random.nextInt(200) + 50,
        ));
      }
    } finally {
      _isSending = false;
    }
  }

  bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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
    WidgetsBinding.instance.removeObserver(this);
    stop();
    _debounceTimer?.cancel();
    if (_hasPendingSave) {
      _saveQueue();
    }
    super.dispose();
  }
}
