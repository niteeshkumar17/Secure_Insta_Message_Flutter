import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/message.dart';
import '../models/delivery_status.dart';
import '../models/core_response.dart';
import 'core_bridge.dart';

/// Service for message sending and receiving.
///
/// All encryption, routing, and delivery logic is handled by
/// the Python core. This service:
/// - Sends commands to the core to send messages
/// - Polls the core for new messages
/// - Tracks delivery status updates
///
/// Messages do NOT include timestamps (forbidden by protocol).
class MessagingService extends ChangeNotifier {
  final CoreBridge _bridge;

  /// Messages indexed by contact ID.
  final Map<String, List<Message>> _messages = {};

  /// Active polling timer.
  Timer? _pollTimer;

  /// Polling interval (generous for Tor latency).
  static const _pollInterval = Duration(seconds: 10);

  bool _isPolling = false;
  bool get isPolling => _isPolling;

  String? _error;
  String? get error => _error;

  StreamSubscription<CoreResponse>? _notificationSub;

  MessagingService(this._bridge) {
    // Listen for unsolicited notifications (new messages, receipts)
    _notificationSub = _bridge.notifications.listen(_onNotification);
  }

  /// Get messages for a specific contact.
  List<Message> getMessages(String contactId) {
    return List.unmodifiable(_messages[contactId] ?? []);
  }

  /// Send a text message to a contact.
  ///
  /// The message is queued in the cover traffic stream by the core.
  /// It will be transmitted when the next cover traffic slot fires.
  /// This prevents timing correlation.
  Future<bool> sendTextMessage({
    required String contactId,
    required String text,
  }) async {
    _error = null;

    final response = await _bridge.send(
      method: 'send_message',
      params: {
        'contact_id': contactId,
        'text': text,
      },
      // Generous timeout: cover traffic delay + Tor + onion routing
      timeout: const Duration(seconds: 30),
    );

    if (response.success && response.result != null) {
      final message = Message.fromJson(response.result!);
      _addMessage(contactId, message);
      return true;
    }

    _error = response.error ?? 'Failed to send message';
    notifyListeners();
    return false;
  }

  /// Send an asynchronous voice message.
  ///
  /// Voice data is loaded from [filePath], encrypted by the core,
  /// and sent through the same onion-routed cover traffic stream.
  ///
  /// No real-time voice calls — only async voice messages.
  Future<bool> sendVoiceMessage({
    required String contactId,
    required String filePath,
  }) async {
    _error = null;

    final response = await _bridge.send(
      method: 'send_voice_message',
      params: {
        'contact_id': contactId,
        'file_path': filePath,
      },
      timeout: const Duration(seconds: 60),
    );

    if (response.success && response.result != null) {
      final message = Message.fromJson(response.result!);
      _addMessage(contactId, message);
      return true;
    }

    _error = response.error ?? 'Failed to send voice message';
    notifyListeners();
    return false;
  }

  /// Start polling for new messages.
  void startPolling() {
    if (_isPolling) return;
    _isPolling = true;
    _pollTimer = Timer.periodic(_pollInterval, (_) => _pollMailbox());
    notifyListeners();
  }

  /// Stop polling.
  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _isPolling = false;
    notifyListeners();
  }

  /// Poll the mailbox for new messages.
  Future<void> _pollMailbox() async {
    final response = await _bridge.send(
      method: 'poll_mailbox',
      timeout: const Duration(seconds: 30),
    );

    if (response.success && response.result != null) {
      final newMessages =
          response.result!['messages'] as List<dynamic>?;
      if (newMessages != null && newMessages.isNotEmpty) {
        for (final msgJson in newMessages) {
          final msg =
              Message.fromJson(msgJson as Map<String, dynamic>);
          _addMessage(msg.contactId, msg);
        }
      }
    }
  }

  /// Load message history for a contact.
  Future<void> loadMessages(String contactId) async {
    final response = await _bridge.send(
      method: 'get_messages',
      params: {'contact_id': contactId},
    );

    if (response.success && response.result != null) {
      final list = response.result!['messages'] as List<dynamic>?;
      if (list != null) {
        _messages[contactId] = list
            .map((m) => Message.fromJson(m as Map<String, dynamic>))
            .toList();
        notifyListeners();
      }
    }
  }

  /// Handle unsolicited notifications from core.
  void _onNotification(CoreResponse notification) {
    if (notification.result == null) return;

    final type = notification.result!['type'] as String?;

    if (type == 'new_message') {
      final msg = Message.fromJson(
          notification.result!['message'] as Map<String, dynamic>);
      _addMessage(msg.contactId, msg);
    } else if (type == 'delivery_receipt') {
      final msgId = notification.result!['message_id'] as String?;
      final contactId = notification.result!['contact_id'] as String?;
      if (msgId != null && contactId != null) {
        _updateDeliveryStatus(
            contactId, msgId, DeliveryStatus.delivered);
      }
    }
  }

  /// Add a message to the local list.
  void _addMessage(String contactId, Message message) {
    _messages[contactId] ??= [];
    // Deduplicate by message ID
    final existing =
        _messages[contactId]!.indexWhere((m) => m.id == message.id);
    if (existing < 0) {
      _messages[contactId]!.add(message);
      notifyListeners();
    }
  }

  /// Update delivery status for a message.
  void _updateDeliveryStatus(
    String contactId,
    String messageId,
    DeliveryStatus status,
  ) {
    final list = _messages[contactId];
    if (list == null) return;

    final index = list.indexWhere((m) => m.id == messageId);
    if (index >= 0) {
      list[index] = list[index].copyWith(deliveryStatus: status);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _notificationSub?.cancel();
    super.dispose();
  }
}

