/// Network status model — read from the Python core.
///
/// The Flutter client only displays this information.
/// It does not control or modify network behavior directly.

/// Tor connection state.
enum TorStatus {
  disconnected,
  connecting,
  connected,
  error;

  static TorStatus fromString(String? value) {
    switch (value) {
      case 'connected':
        return TorStatus.connected;
      case 'connecting':
        return TorStatus.connecting;
      case 'error':
        return TorStatus.error;
      default:
        return TorStatus.disconnected;
    }
  }
}

/// A relay node as reported by the core.
class RelayInfo {
  final String address;
  final int port;
  final String publicKeyFingerprint;
  final bool isReachable;

  const RelayInfo({
    required this.address,
    required this.port,
    required this.publicKeyFingerprint,
    this.isReachable = false,
  });

  factory RelayInfo.fromJson(Map<String, dynamic> json) => RelayInfo(
        address: json['address'] as String? ?? '',
        port: json['port'] as int? ?? 0,
        publicKeyFingerprint: json['public_key_fingerprint'] as String? ?? '',
        isReachable: json['is_reachable'] as bool? ?? false,
      );
}

/// Mailbox status as reported by the core.
class MailboxStatus {
  final String address;
  final int port;
  final bool isReachable;
  final int pendingCount;

  const MailboxStatus({
    required this.address,
    required this.port,
    this.isReachable = false,
    this.pendingCount = 0,
  });

  factory MailboxStatus.fromJson(Map<String, dynamic> json) => MailboxStatus(
        address: json['address'] as String? ?? '',
        port: json['port'] as int? ?? 0,
        isReachable: json['is_reachable'] as bool? ?? false,
        pendingCount: json['pending_count'] as int? ?? 0,
      );
}

/// Aggregate network status.
class NetworkStatus {
  final TorStatus torStatus;
  final String? torCircuitInfo;
  final List<RelayInfo> relays;
  final MailboxStatus? mailbox;
  final bool coverTrafficActive;
  final int coverPacketsSent;
  final int realPacketsSent;

  const NetworkStatus({
    this.torStatus = TorStatus.disconnected,
    this.torCircuitInfo,
    this.relays = const [],
    this.mailbox,
    this.coverTrafficActive = false,
    this.coverPacketsSent = 0,
    this.realPacketsSent = 0,
  });

  factory NetworkStatus.fromJson(Map<String, dynamic> json) => NetworkStatus(
        torStatus: TorStatus.fromString(json['tor_status'] as String?),
        torCircuitInfo: json['tor_circuit_info'] as String?,
        relays: (json['relays'] as List<dynamic>?)
                ?.map((r) =>
                    RelayInfo.fromJson(r as Map<String, dynamic>))
                .toList() ??
            [],
        mailbox: json['mailbox'] != null
            ? MailboxStatus.fromJson(
                json['mailbox'] as Map<String, dynamic>)
            : null,
        coverTrafficActive: json['cover_traffic_active'] as bool? ?? false,
        coverPacketsSent: json['cover_packets_sent'] as int? ?? 0,
        realPacketsSent: json['real_packets_sent'] as int? ?? 0,
      );

  /// Whether the network is in a usable state.
  bool get isOperational =>
      torStatus == TorStatus.connected && coverTrafficActive;
}

