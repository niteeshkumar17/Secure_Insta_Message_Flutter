/// TorManager — Flutter service for managing embedded Tor daemon
///
/// Provides Dart interface to control TorService via MethodChannel.
/// Implements kill-switch: messaging blocked unless Tor is fully connected.

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Tor connection state (mirrors TorService.TorState in Kotlin)
enum TorState {
  stopped,
  starting,
  connecting,
  connected,
  error;

  static TorState fromString(String value) {
    return TorState.values.firstWhere(
      (e) => e.name.toUpperCase() == value.toUpperCase(),
      orElse: () => TorState.stopped,
    );
  }
}

/// Tor status snapshot
class TorStatus {
  final TorState state;
  final int bootstrapProgress;
  final String? errorMessage;
  final bool isRunning;

  const TorStatus({
    required this.state,
    required this.bootstrapProgress,
    this.errorMessage,
    required this.isRunning,
  });

  factory TorStatus.initial() => const TorStatus(
        state: TorState.stopped,
        bootstrapProgress: 0,
        errorMessage: null,
        isRunning: false,
      );

  factory TorStatus.fromMap(Map<dynamic, dynamic> map) {
    return TorStatus(
      state: TorState.fromString(map['state'] as String? ?? 'STOPPED'),
      bootstrapProgress: map['bootstrapProgress'] as int? ?? 0,
      errorMessage: map['errorMessage'] as String?,
      isRunning: map['isRunning'] as bool? ?? false,
    );
  }

  /// True if Tor is fully connected and ready for traffic
  bool get isConnected => state == TorState.connected && bootstrapProgress >= 100;

  /// Kill-switch check: returns true only if messaging is allowed
  bool get isNetworkAllowed => isConnected;

  @override
  String toString() =>
      'TorStatus(state: $state, bootstrap: $bootstrapProgress%, running: $isRunning)';
}

/// TorManager — manages embedded Tor lifecycle from Flutter
class TorManager extends ChangeNotifier {
  static const _channel = MethodChannel('com.securemessage/tor');

  TorStatus _status = TorStatus.initial();
  int _socksPort = -1;
  Timer? _pollTimer;
  bool _isPolling = false;

  TorStatus get status => _status;
  int get socksPort => _socksPort;

  /// True if messaging is allowed (kill-switch check)
  bool get isNetworkAllowed => _status.isNetworkAllowed;

  /// Bootstrap progress (0-100)
  int get bootstrapProgress => _status.bootstrapProgress;

  /// Human-readable status for UI
  String get statusText {
    switch (_status.state) {
      case TorState.stopped:
        return 'Tor stopped';
      case TorState.starting:
        return 'Starting Tor...';
      case TorState.connecting:
        return 'Connecting: ${_status.bootstrapProgress}%';
      case TorState.connected:
        return 'Connected via Tor';
      case TorState.error:
        return _status.errorMessage ?? 'Tor error';
    }
  }

  /// Start the embedded Tor daemon
  Future<void> startTor() async {
    try {
      await _channel.invokeMethod('startTor');
      _startPolling();
    } on PlatformException catch (e) {
      debugPrint('TorManager: Failed to start Tor: ${e.message}');
      _status = TorStatus(
        state: TorState.error,
        bootstrapProgress: 0,
        errorMessage: e.message,
        isRunning: false,
      );
      notifyListeners();
    }
  }

  /// Stop the embedded Tor daemon
  Future<void> stopTor() async {
    try {
      _stopPolling();
      await _channel.invokeMethod('stopTor');
      _status = TorStatus.initial();
      _socksPort = -1;
      notifyListeners();
    } on PlatformException catch (e) {
      debugPrint('TorManager: Failed to stop Tor: ${e.message}');
    }
  }

  /// Get current Tor status from native
  Future<TorStatus> getTorStatus() async {
    try {
      final result = await _channel.invokeMethod('getTorStatus');
      if (result is Map) {
        return TorStatus.fromMap(result);
      }
    } on PlatformException catch (e) {
      debugPrint('TorManager: Failed to get status: ${e.message}');
    }
    return TorStatus.initial();
  }

  /// Get SOCKS proxy port (-1 if not connected)
  Future<int> getSocksPort() async {
    try {
      final result = await _channel.invokeMethod('getSocksPort');
      return result as int? ?? -1;
    } on PlatformException catch (e) {
      debugPrint('TorManager: Failed to get SOCKS port: ${e.message}');
      return -1;
    }
  }

  /// Check if SOCKS proxy is reachable
  Future<bool> isSocksReachable() async {
    try {
      final result = await _channel.invokeMethod('isSocksReachable');
      return result as bool? ?? false;
    } on PlatformException catch (e) {
      debugPrint('TorManager: Failed to check SOCKS: ${e.message}');
      return false;
    }
  }

  /// Start polling for status updates
  void _startPolling() {
    if (_isPolling) return;
    _isPolling = true;
    
    // Poll every 500ms during bootstrap, then slow down
    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      await _updateStatus();
      
      // Slow down polling once connected
      if (_status.isConnected && _pollTimer?.isActive == true) {
        _pollTimer?.cancel();
        _pollTimer = Timer.periodic(
          const Duration(seconds: 5),
          (_) => _updateStatus(),
        );
      }
    });
  }

  /// Stop polling
  void _stopPolling() {
    _isPolling = false;
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// Update status from native
  Future<void> _updateStatus() async {
    final newStatus = await getTorStatus();
    final newPort = await getSocksPort();

    if (_status != newStatus || _socksPort != newPort) {
      _status = newStatus;
      _socksPort = newPort;
      notifyListeners();
    }
  }

  /// Refresh status immediately
  Future<void> refresh() async {
    await _updateStatus();
  }

  /// Initialize and start monitoring
  Future<void> initialize() async {
    await _updateStatus();
    
    // If already running (from previous session), start polling
    if (_status.isRunning) {
      _startPolling();
    }
  }

  @override
  void dispose() {
    _stopPolling();
    super.dispose();
  }
}

