import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/network_status.dart';
import 'core_bridge.dart';

/// Service for network status monitoring.
///
/// Periodically queries the Python core for:
/// - Tor connection status
/// - Relay availability
/// - Mailbox reachability
/// - Cover traffic statistics
///
/// This service ONLY reads status. It does not control
/// networking — that is entirely managed by the core.
class NetworkService extends ChangeNotifier {
  final CoreBridge _bridge;

  NetworkStatus _status = const NetworkStatus();
  NetworkStatus get status => _status;

  Timer? _pollTimer;
  static const _pollInterval = Duration(seconds: 5);

  bool _isMonitoring = false;
  bool get isMonitoring => _isMonitoring;

  NetworkService(this._bridge);

  /// Start monitoring network status.
  void startMonitoring() {
    if (_isMonitoring) return;
    _isMonitoring = true;
    _pollTimer =
        Timer.periodic(_pollInterval, (_) => refreshStatus());
    refreshStatus(); // Immediate first check
    notifyListeners();
  }

  /// Stop monitoring.
  void stopMonitoring() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _isMonitoring = false;
    notifyListeners();
  }

  /// Refresh network status from the core.
  Future<void> refreshStatus() async {
    final response =
        await _bridge.send(method: 'get_network_status');

    if (response.success && response.result != null) {
      _status = NetworkStatus.fromJson(response.result!);
      notifyListeners();
    }
  }

  /// Configure relay preferences.
  Future<bool> configureRelay({
    required String address,
    required int port,
  }) async {
    final response = await _bridge.send(
      method: 'configure_relay',
      params: {'address': address, 'port': port},
    );
    if (response.success) {
      await refreshStatus();
      return true;
    }
    return false;
  }

  /// Configure mailbox address.
  Future<bool> configureMailbox({
    required String address,
    required int port,
  }) async {
    final response = await _bridge.send(
      method: 'configure_mailbox',
      params: {'address': address, 'port': port},
    );
    if (response.success) {
      await refreshStatus();
      return true;
    }
    return false;
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }
}

