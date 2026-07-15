import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// SOCKS5 client for sending HTTP requests through Tor proxy.
///
/// Implements SOCKS5 protocol to connect to .onion addresses via Tor's
/// SOCKS proxy running on localhost:9050.
///
/// NOTE ON CONNECTION REUSE:
/// This custom client does not support HTTP Keep-Alive / connection reuse.
/// Each `post(...)` request establishes a new TCP connection and SOCKS5 handshake,
/// and reads the response until EOF (the server closes the socket). The mailbox
/// server also terminates the connection after sending the response by writing
/// `Connection: close` and closing the writer.
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

      final iterator = StreamIterator(socket);

      // Read handshake response
      final handshakeResponse = await _readBytes(iterator, 2, timeout);
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
      final connectResponse = await _readBytes(iterator, 10, timeout);
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
      final response = await _readHttpResponse(iterator, timeout);
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

  /// Check if a hidden service is reachable via SOCKS5 proxy
  Future<bool> checkReachability(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    Socket? socket;

    try {
      socket = await Socket.connect(
        proxyHost,
        proxyPort,
        timeout: timeout,
      );

      socket.add([0x05, 0x01, 0x00]);
      await socket.flush();

      final iterator = StreamIterator(socket);
      final handshakeResponse = await _readBytes(iterator, 2, timeout);
      if (handshakeResponse == null ||
          handshakeResponse[0] != 0x05 ||
          handshakeResponse[1] != 0x00) {
        return false;
      }

      final hostBytes = utf8.encode(host);
      final connectRequest = [
        0x05, 0x01, 0x00, 0x03,
        hostBytes.length,
        ...hostBytes,
        (port >> 8) & 0xFF,
        port & 0xFF,
      ];

      socket.add(connectRequest);
      await socket.flush();

      final connectResponse = await _readBytes(iterator, 10, timeout);
      if (connectResponse == null ||
          connectResponse[0] != 0x05 ||
          connectResponse[1] != 0x00) {
        return false;
      }

      return true;
    } catch (e) {
      debugPrint('SOCKS5: Error checking reachability to $host:$port - $e');
      return false;
    } finally {
      socket?.destroy();
    }
  }

  /// Read exactly [count] bytes from stream iterator with timeout.
  Future<List<int>?> _readBytes(
      StreamIterator<List<int>> iterator, int count, Duration timeout) async {
    final buffer = <int>[];
    
    try {
      while (buffer.length < count) {
        final moved = await iterator.moveNext().timeout(timeout);
        if (!moved) break;
        buffer.addAll(iterator.current);
      }
    } catch (e) {
      return null;
    }

    return buffer.length >= count ? buffer.sublist(0, count) : null;
  }

  /// Read HTTP response from stream iterator.
  Future<String?> _readHttpResponse(
      StreamIterator<List<int>> iterator, Duration timeout) async {
    final buffer = <int>[];
    
    try {
      while (true) {
        final moved = await iterator.moveNext().timeout(timeout);
        if (!moved) break;
        buffer.addAll(iterator.current);
        
        final responseStr = utf8.decode(buffer, allowMalformed: true);
        final headersEnd = responseStr.indexOf('\r\n\r\n');
        if (headersEnd != -1) {
          final headers = responseStr.substring(0, headersEnd).toLowerCase();
          final contentLengthMatch = RegExp(r'content-length:\s*(\d+)').firstMatch(headers);
          if (contentLengthMatch != null) {
            final contentLength = int.parse(contentLengthMatch.group(1)!);
            final bodyLength = buffer.length - (headersEnd + 4);
            if (bodyLength >= contentLength) {
              break;
            }
          }
        }
      }
    } catch (e) {
      // Timeout or error, return what we have so far
    }

    final responseStr = utf8.decode(buffer, allowMalformed: true);
    return responseStr.isEmpty ? null : responseStr;
  }
}
