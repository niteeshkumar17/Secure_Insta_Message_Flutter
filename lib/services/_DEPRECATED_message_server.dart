import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// Message payload received from other devices via Tor hidden service
class IncomingMessage {
  final String senderOnion;
  final String messageId;
  final String text;
  final DateTime timestamp;

  IncomingMessage({
    required this.senderOnion,
    required this.messageId,
    required this.text,
    required this.timestamp,
  });

  factory IncomingMessage.fromJson(Map<String, dynamic> json) {
    return IncomingMessage(
      senderOnion: json['sender_onion'] as String,
      messageId: json['message_id'] as String,
      text: json['text'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        json['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        'sender_onion': senderOnion,
        'message_id': messageId,
        'text': text,
        'timestamp': timestamp.millisecondsSinceEpoch,
      };
}

/// HTTP server that listens for incoming messages via Tor hidden service.
///
/// Runs on localhost:8080 - Tor routes hidden service traffic here.
/// Other devices connect to our .onion address on port 80, which Tor
/// forwards to this local server.
class MessageServer extends ChangeNotifier {
  HttpServer? _server;
  final int _port;
  bool _isRunning = false;

  /// Callback when a message is received
  final void Function(IncomingMessage message)? onMessageReceived;

  /// Callback when a delivery receipt is received
  final void Function(String messageId, String fromOnion)? onDeliveryReceipt;

  MessageServer({
    int port = 8080,
    this.onMessageReceived,
    this.onDeliveryReceipt,
  }) : _port = port;

  bool get isRunning => _isRunning;
  int get port => _port;

  /// Start the HTTP server
  Future<bool> start() async {
    if (_isRunning) {
      debugPrint('MessageServer: Already running');
      return true;
    }

    try {
      _server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        _port,
        shared: true,
      );
      _isRunning = true;
      debugPrint('MessageServer: Listening on localhost:$_port');

      // Handle incoming requests
      _server!.listen(_handleRequest, onError: (e) {
        debugPrint('MessageServer: Error: $e');
      });

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('MessageServer: Failed to start: $e');
      _isRunning = false;
      return false;
    }
  }

  /// Stop the HTTP server
  Future<void> stop() async {
    if (!_isRunning) return;

    try {
      await _server?.close(force: true);
      _server = null;
      _isRunning = false;
      debugPrint('MessageServer: Stopped');
      notifyListeners();
    } catch (e) {
      debugPrint('MessageServer: Error stopping: $e');
    }
  }

  /// Handle incoming HTTP request
  void _handleRequest(HttpRequest request) async {
    final method = request.method;
    final path = request.uri.path;

    debugPrint('MessageServer: $method $path');

    try {
      // Allow CORS for testing
      request.response.headers.set('Access-Control-Allow-Origin', '*');
      request.response.headers.contentType = ContentType.json;

      if (method == 'POST' && path == '/message') {
        await _handleMessage(request);
      } else if (method == 'POST' && path == '/receipt') {
        await _handleReceipt(request);
      } else if (method == 'GET' && path == '/ping') {
        // Health check endpoint
        request.response.statusCode = 200;
        request.response.write(jsonEncode({'status': 'ok'}));
      } else {
        request.response.statusCode = 404;
        request.response.write(jsonEncode({'error': 'Not found'}));
      }
    } catch (e) {
      debugPrint('MessageServer: Request error: $e');
      request.response.statusCode = 500;
      request.response.write(jsonEncode({'error': 'Internal error'}));
    } finally {
      await request.response.close();
    }
  }

  /// Handle incoming message
  Future<void> _handleMessage(HttpRequest request) async {
    try {
      final body = await utf8.decoder.bind(request).join();
      final json = jsonDecode(body) as Map<String, dynamic>;

      final message = IncomingMessage.fromJson(json);
      debugPrint(
          'MessageServer: Received message from ${message.senderOnion}: ${message.text}');

      // Notify listener
      if (onMessageReceived != null) {
        onMessageReceived!(message);
      }

      request.response.statusCode = 200;
      request.response.write(jsonEncode({
        'status': 'received',
        'message_id': message.messageId,
      }));
    } catch (e) {
      debugPrint('MessageServer: Failed to parse message: $e');
      request.response.statusCode = 400;
      request.response.write(jsonEncode({'error': 'Invalid message format'}));
    }
  }

  /// Handle delivery receipt
  Future<void> _handleReceipt(HttpRequest request) async {
    try {
      final body = await utf8.decoder.bind(request).join();
      final json = jsonDecode(body) as Map<String, dynamic>;

      final messageId = json['message_id'] as String;
      final fromOnion = json['from_onion'] as String;

      debugPrint('MessageServer: Received receipt for $messageId from $fromOnion');

      // Notify listener
      if (onDeliveryReceipt != null) {
        onDeliveryReceipt!(messageId, fromOnion);
      }

      request.response.statusCode = 200;
      request.response.write(jsonEncode({'status': 'ok'}));
    } catch (e) {
      debugPrint('MessageServer: Failed to parse receipt: $e');
      request.response.statusCode = 400;
      request.response.write(jsonEncode({'error': 'Invalid receipt format'}));
    }
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
