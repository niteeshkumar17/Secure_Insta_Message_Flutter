import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// SOCKS5 client for sending HTTP requests through Tor proxy.
///
/// Implements SOCKS5 protocol to connect to .onion addresses via Tor's
/// SOCKS proxy running on localhost:9050.
class Socks5Client {
  final String proxyHost;
  final int proxyPort;

  Socks5Client({
    this.proxyHost = '127.0.0.1',
    this.proxyPort = 9050,
  });

  /// Send an HTTP POST request through the SOCKS5 proxy.
  ///
  /// [host] - The destination host (e.g., "abc123.onion")
  /// [port] - The destination port (usually 80)
  /// [path] - The HTTP path (e.g., "/message")
  /// [body] - The JSON body to send
  ///
  /// Returns the response body as a Map, or null on error.
  Future<Map<String, dynamic>?> post(
    String host,
    int port,
    String path,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    Socket? socket;

    try {
      // Connect to SOCKS proxy
      socket = await Socket.connect(
        proxyHost,
        proxyPort,
        timeout: timeout,
      );

      // SOCKS5 handshake - no authentication
      // Version 5, 1 auth method, no auth (0x00)
      socket.add([0x05, 0x01, 0x00]);
      await socket.flush();

      // Read handshake response
      final handshakeResponse = await _readBytes(socket, 2, timeout);
      if (handshakeResponse == null ||
          handshakeResponse[0] != 0x05 ||
          handshakeResponse[1] != 0x00) {
        debugPrint(
            'SOCKS5: Handshake failed: ${handshakeResponse?.map((b) => '0x${b.toRadixString(16)}').join(', ')}');
        return null;
      }

      // Send CONNECT request for domain name
      // 0x05 = version
      // 0x01 = CONNECT command
      // 0x00 = reserved
      // 0x03 = domain name address type
      // domain_len, domain_bytes, port (2 bytes big-endian)
      final hostBytes = utf8.encode(host);
      final connectRequest = [
        0x05, // version
        0x01, // CONNECT
        0x00, // reserved
        0x03, // domain name
        hostBytes.length, // domain length
        ...hostBytes, // domain
        (port >> 8) & 0xFF, // port high byte
        port & 0xFF, // port low byte
      ];

      socket.add(connectRequest);
      await socket.flush();

      // Read CONNECT response (at least 10 bytes for IPv4 response)
      final connectResponse = await _readBytes(socket, 10, timeout);
      if (connectResponse == null ||
          connectResponse[0] != 0x05 ||
          connectResponse[1] != 0x00) {
        final errorCode =
            connectResponse != null && connectResponse.length >= 2
                ? connectResponse[1]
                : -1;
        debugPrint('SOCKS5: Connect failed with code: $errorCode');
        return null;
      }

      debugPrint('SOCKS5: Connected to $host:$port via Tor');

      // Now we have a connected socket - send HTTP request
      final jsonBody = jsonEncode(body);
      final httpRequest = 'POST $path HTTP/1.1\r\n'
          'Host: $host\r\n'
          'Content-Type: application/json\r\n'
          'Content-Length: ${utf8.encode(jsonBody).length}\r\n'
          'Connection: close\r\n'
          '\r\n'
          '$jsonBody';

      socket.add(utf8.encode(httpRequest));
      await socket.flush();

      // Read HTTP response
      final response = await _readHttpResponse(socket, timeout);
      if (response == null) {
        debugPrint('SOCKS5: No HTTP response received');
        return null;
      }

      debugPrint('SOCKS5: Response: $response');

      // Parse JSON body from response
      final bodyStart = response.indexOf('\r\n\r\n');
      if (bodyStart == -1) {
        debugPrint('SOCKS5: Invalid HTTP response format');
        return null;
      }

      final responseBody = response.substring(bodyStart + 4);
      try {
        return jsonDecode(responseBody) as Map<String, dynamic>;
      } catch (e) {
        debugPrint('SOCKS5: Failed to parse JSON response: $e');
        return null;
      }
    } catch (e) {
      debugPrint('SOCKS5: Error: $e');
      return null;
    } finally {
      await socket?.close();
    }
  }

  /// Read exactly [count] bytes from socket with timeout.
  Future<List<int>?> _readBytes(
      Socket socket, int count, Duration timeout) async {
    final completer = Completer<List<int>?>();
    final buffer = <int>[];
    StreamSubscription? subscription;
    Timer? timer;

    timer = Timer(timeout, () {
      subscription?.cancel();
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    });

    subscription = socket.listen(
      (data) {
        buffer.addAll(data);
        if (buffer.length >= count) {
          timer?.cancel();
          subscription?.cancel();
          if (!completer.isCompleted) {
            completer.complete(buffer.sublist(0, count));
          }
        }
      },
      onError: (e) {
        timer?.cancel();
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      },
      onDone: () {
        timer?.cancel();
        if (!completer.isCompleted) {
          completer.complete(buffer.length >= count ? buffer.sublist(0, count) : null);
        }
      },
    );

    return completer.future;
  }

  /// Read HTTP response from socket.
  Future<String?> _readHttpResponse(Socket socket, Duration timeout) async {
    final completer = Completer<String?>();
    final buffer = StringBuffer();
    StreamSubscription? subscription;
    Timer? timer;

    timer = Timer(timeout, () {
      subscription?.cancel();
      if (!completer.isCompleted) {
        completer.complete(buffer.toString().isEmpty ? null : buffer.toString());
      }
    });

    subscription = socket.listen(
      (data) {
        buffer.write(utf8.decode(data, allowMalformed: true));
        
        // Check if we've received the complete response
        final content = buffer.toString();
        if (content.contains('\r\n\r\n')) {
          // Check for Content-Length or chunked encoding
          final headerEnd = content.indexOf('\r\n\r\n');
          final headers = content.substring(0, headerEnd).toLowerCase();
          
          if (headers.contains('content-length:')) {
            // Parse content length
            final match =
                RegExp(r'content-length:\s*(\d+)').firstMatch(headers);
            if (match != null) {
              final contentLength = int.parse(match.group(1)!);
              final bodyStart = headerEnd + 4;
              final body = content.substring(bodyStart);
              if (body.length >= contentLength) {
                timer?.cancel();
                subscription?.cancel();
                if (!completer.isCompleted) {
                  completer.complete(content);
                }
              }
            }
          } else if (headers.contains('connection: close')) {
            // Wait for connection to close
          }
        }
      },
      onError: (e) {
        timer?.cancel();
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      },
      onDone: () {
        timer?.cancel();
        if (!completer.isCompleted) {
          completer.complete(buffer.toString().isEmpty ? null : buffer.toString());
        }
      },
    );

    return completer.future;
  }
}
