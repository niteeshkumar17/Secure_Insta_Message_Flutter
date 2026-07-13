import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/network_status.dart';
import 'core_bridge.dart';

enum MailboxSource {
  runtime,
  configured,
  builtInDefault,
  none,
}

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
  final _storage = const FlutterSecureStorage();

  static const _mailboxAddressKey = 'default_mailbox_address';
  static const _mailboxPortKey = 'default_mailbox_port';
  static const _builtInMailboxAddress =
      String.fromEnvironment('DEFAULT_MAILBOX_ONION', defaultValue: '');
  static const _builtInMailboxPort =
      int.fromEnvironment('DEFAULT_MAILBOX_PORT', defaultValue: 80);

  NetworkStatus _status = const NetworkStatus();
  NetworkStatus get status => _status;

  Timer? _pollTimer;
  static const _pollInterval = Duration(seconds: 5);

  bool _isMonitoring = false;
  bool get isMonitoring => _isMonitoring;

  String? _configuredMailboxAddress;
  int? _configuredMailboxPort;
  bool _mailboxConfigLoaded = false;

  MailboxStatus? get effectiveMailbox {
    if (_status.mailbox != null) return _status.mailbox;

    final configured = _configuredMailboxAddress?.trim();
    if (configured != null && configured.isNotEmpty) {
      return MailboxStatus(
        address: configured,
        port: _configuredMailboxPort ?? _builtInMailboxPort,
      );
    }

    if (_builtInMailboxAddress.trim().isNotEmpty) {
      return const MailboxStatus(
        address: _builtInMailboxAddress,
        port: _builtInMailboxPort,
      );
    }

    return null;
  }

  MailboxSource get mailboxSource {
    if (_status.mailbox != null) {
      return MailboxSource.runtime;
    }

    final configured = _configuredMailboxAddress?.trim();
    if (configured != null && configured.isNotEmpty) {
      return MailboxSource.configured;
    }

    if (_builtInMailboxAddress.trim().isNotEmpty) {
      return MailboxSource.builtInDefault;
    }

    return MailboxSource.none;
  }

  NetworkService(this._bridge);

  Future<void> _ensureMailboxConfigLoaded() async {
    if (_mailboxConfigLoaded) return;

    _configuredMailboxAddress = await _storage.read(key: _mailboxAddressKey);
    final storedPort = await _storage.read(key: _mailboxPortKey);
    _configuredMailboxPort = int.tryParse(storedPort ?? '');
    _mailboxConfigLoaded = true;
  }

  Future<void> _persistMailboxConfig({
    required String address,
    required int port,
  }) async {
    _configuredMailboxAddress = address;
    _configuredMailboxPort = port;
    await _storage.write(key: _mailboxAddressKey, value: address);
    await _storage.write(key: _mailboxPortKey, value: port.toString());
  }

  /// Start monitoring network status.
  void startMonitoring() {
    if (_isMonitoring) return;
    _isMonitoring = true;
    _pollTimer =
        Timer.periodic(_pollInterval, (_) => refreshStatus());
    unawaited(refreshStatus());
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
    await _ensureMailboxConfigLoaded();

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
    await _ensureMailboxConfigLoaded();
    await _persistMailboxConfig(address: address, port: port);

    final response = await _bridge.send(
      method: 'configure_mailbox',
      params: {'address': address, 'port': port},
    );

    await refreshStatus();
    return response.success;
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }
}

