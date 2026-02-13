import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/network_service.dart';
import '../services/tor_manager.dart';
import '../models/network_status.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';

/// Network Status Screen (Screen 4)
///
/// Displays:
/// - Embedded Tor status and bootstrap progress
/// - Relay list
/// - Mailbox status
/// - Cover traffic indicator
///
/// This screen is read-only — the user can see the state but
/// all networking is managed by the embedded Tor and Python core.
class NetworkStatusScreen extends StatefulWidget {
  const NetworkStatusScreen({super.key});

  @override
  State<NetworkStatusScreen> createState() => _NetworkStatusScreenState();
}

class _NetworkStatusScreenState extends State<NetworkStatusScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final service = context.read<NetworkService>();
      if (!service.isMonitoring) {
        service.startMonitoring();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<TorManager, NetworkService>(
      builder: (context, tor, service, _) {
        final status = service.status;

        return Scaffold(
          appBar: AppBar(
            title: const Text('Network Status'),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh',
                onPressed: () {
                  tor.refresh();
                  service.refreshStatus();
                },
              ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Embedded Tor Status
                _buildEmbeddedTorCard(context, tor),
                const SizedBox(height: 12),

                // Cover Traffic
                _buildCoverTrafficCard(context, status),
                const SizedBox(height: 12),

                // Relay List
                _buildRelayCard(context, status),
                const SizedBox(height: 12),

                // Mailbox Status
                _buildMailboxCard(context, status),
                const SizedBox(height: 12),

                // Configuration
                _buildConfigCard(context, service),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Embedded Tor status card (replaces old _buildTorStatusCard)
  Widget _buildEmbeddedTorCard(BuildContext context, TorManager tor) {
    final status = tor.status;
    Color statusColor;
    String statusText;
    IconData statusIcon;

    switch (status.state) {
      case TorState.connected:
        statusColor = AppTheme.success;
        statusText = 'Connected via Embedded Tor';
        statusIcon = Icons.shield;
      case TorState.connecting:
        statusColor = AppTheme.warning;
        statusText = 'Bootstrapping: ${status.bootstrapProgress}%';
        statusIcon = Icons.sync;
      case TorState.starting:
        statusColor = AppTheme.warning;
        statusText = 'Starting Tor daemon...';
        statusIcon = Icons.hourglass_top;
      case TorState.error:
        statusColor = AppTheme.error;
        statusText = status.errorMessage ?? 'Tor Error';
        statusIcon = Icons.error;
      case TorState.stopped:
        statusColor = AppTheme.error;
        statusText = 'Tor Stopped — Kill-switch Active';
        statusIcon = Icons.shield_outlined;
    }

    return SecurityCard(
      title: 'Embedded Tor',
      icon: Icons.security,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusDot(color: statusColor, size: 12),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  statusText,
                  style: TextStyle(
                    color: statusColor,
                    fontWeight: FontWeight.w500,
                    fontSize: 15,
                  ),
                ),
              ),
            ],
          ),
          
          // Bootstrap progress bar
          if (status.state == TorState.connecting) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: status.bootstrapProgress / 100,
                backgroundColor: AppTheme.surface,
                valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primary),
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${status.bootstrapProgress}% complete',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          
          // SOCKS port info when connected
          if (status.isConnected && tor.socksPort > 0) ...[
            const SizedBox(height: 8),
            MonospaceText(
              text: 'SOCKS: 127.0.0.1:${tor.socksPort}',
              fontSize: 11,
              color: AppTheme.textSecondary,
            ),
          ],
          
          // Kill-switch explanation
          if (!status.isConnected) ...[
            const SizedBox(height: 12),
            Text(
              'The app refuses to operate without Tor. '
              'No Orbot required — Tor is embedded directly. '
              'This is a security feature, not a bug.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          
          const SizedBox(height: 12),
          _buildTorInfo(),
        ],
      ),
    );
  }
  
  Widget _buildTorInfo() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Embedded Tor Features',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          _buildFeatureRow(Icons.check, 'No external apps required'),
          _buildFeatureRow(Icons.check, 'Automatic startup'),
          _buildFeatureRow(Icons.check, 'Localhost-only binding'),
          _buildFeatureRow(Icons.check, 'Cookie authentication'),
          _buildFeatureRow(Icons.check, 'Kill-switch enforced'),
        ],
      ),
    );
  }
  
  Widget _buildFeatureRow(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: AppTheme.success),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCoverTrafficCard(
      BuildContext context, NetworkStatus status) {
    return SecurityCard(
      title: 'Cover Traffic',
      icon: Icons.waves,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusDot(
                color: status.coverTrafficActive
                    ? AppTheme.success
                    : AppTheme.warning,
                size: 10,
              ),
              const SizedBox(width: 10),
              Text(
                status.coverTrafficActive ? 'Active' : 'Paused',
                style: TextStyle(
                  color: status.coverTrafficActive
                      ? AppTheme.success
                      : AppTheme.warning,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _StatBox(
                label: 'Cover Packets',
                value: '${status.coverPacketsSent}',
              ),
              const SizedBox(width: 24),
              _StatBox(
                label: 'Real Packets',
                value: '${status.realPacketsSent}',
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Cover traffic makes real messages indistinguishable '
            'from dummy packets (2s ± 30% interval).',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (!status.coverTrafficActive) ...[
            const SizedBox(height: 8),
            Text(
              '⚠ Cover traffic may pause on mobile due to OS '
              'power management. Desktop CLI provides stronger '
              'anonymity.',
              style: TextStyle(
                  color: AppTheme.warning, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRelayCard(
      BuildContext context, NetworkStatus status) {
    return SecurityCard(
      title: 'Relay Directory (min 3 hops)',
      icon: Icons.hub,
      child: status.relays.isEmpty
          ? Text(
              'No relays available. The relay directory has not '
              'been loaded yet.',
              style: Theme.of(context).textTheme.bodySmall,
            )
          : Column(
              children: status.relays
                  .map((relay) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            StatusDot(
                              color: relay.isReachable
                                  ? AppTheme.success
                                  : AppTheme.error,
                              size: 6,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: MonospaceText(
                                text: relay.address,
                                fontSize: 10,
                                color: AppTheme.textSecondary,
                                selectable: false,
                              ),
                            ),
                          ],
                        ),
                      ))
                  .toList(),
            ),
    );
  }

  Widget _buildMailboxCard(
      BuildContext context, NetworkStatus status) {
    final mailbox = status.mailbox;

    return SecurityCard(
      title: 'Mailbox (Dead Drop)',
      icon: Icons.markunread_mailbox_outlined,
      child: mailbox == null
          ? Text(
              'No mailbox configured. Messages cannot be received.',
              style: Theme.of(context).textTheme.bodySmall,
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    StatusDot(
                      color: mailbox.isReachable
                          ? AppTheme.success
                          : AppTheme.error,
                      size: 8,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      mailbox.isReachable
                          ? 'Reachable'
                          : 'Unreachable',
                      style: TextStyle(
                        color: mailbox.isReachable
                            ? AppTheme.success
                            : AppTheme.error,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                MonospaceText(
                  text: '${mailbox.address}:${mailbox.port}',
                  fontSize: 11,
                  color: AppTheme.textSecondary,
                ),
                const SizedBox(height: 4),
                Text(
                  'Pending messages: ${mailbox.pendingCount}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
    );
  }

  Widget _buildConfigCard(
      BuildContext context, NetworkService service) {
    return SecurityCard(
      title: 'Manual Configuration',
      icon: Icons.settings,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Advanced: manually configure relay and mailbox addresses.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.hub, size: 16),
            label: const Text('Configure Relays'),
            onPressed: () =>
                _showConfigDialog(context, service, isRelay: true),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.markunread_mailbox_outlined, size: 16),
            label: const Text('Configure Mailbox'),
            onPressed: () =>
                _showConfigDialog(context, service, isRelay: false),
          ),
        ],
      ),
    );
  }

  void _showConfigDialog(
    BuildContext context,
    NetworkService service, {
    required bool isRelay,
  }) {
    final addressCtrl = TextEditingController();
    final portCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(isRelay ? 'Configure Relay' : 'Configure Mailbox'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: addressCtrl,
              decoration: const InputDecoration(
                labelText: '.onion Address',
                hintText: 'xxxxx.onion',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: portCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Port',
                hintText: '8765',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final address = addressCtrl.text.trim();
              final port = int.tryParse(portCtrl.text.trim()) ?? 0;
              if (address.isNotEmpty && port > 0) {
                Navigator.of(ctx).pop();
                if (isRelay) {
                  service.configureRelay(
                      address: address, port: port);
                } else {
                  service.configureMailbox(
                      address: address, port: port);
                }
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

/// Small stat display box.
class _StatBox extends StatelessWidget {
  final String label;
  final String value;

  const _StatBox({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: TextStyle(
            color: AppTheme.primary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
            fontFamily: 'monospace',
          ),
        ),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

