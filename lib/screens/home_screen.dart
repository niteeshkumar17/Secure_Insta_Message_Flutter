import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/core_bridge.dart';
import '../services/identity_service.dart';
import '../services/network_service.dart';
import '../services/tor_manager.dart';
import '../models/network_status.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import 'identity_screen.dart';
import 'contacts_screen.dart';
import 'network_status_screen.dart';
import 'about_screen.dart';

/// Home screen — the main navigation hub.
///
/// Displays:
/// - Embedded Tor status (bootstrap progress, connected state)
/// - Core bridge connection status
/// - Navigation to all screens
/// - Kill-switch warnings when Tor not connected
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;
  bool _onionAddressUpdated = false;

  static const _screens = <Widget>[
    ContactsScreen(),
    IdentityScreen(),
    NetworkStatusScreen(),
    AboutScreen(),
  ];

  static const _navItems = <BottomNavigationBarItem>[
    BottomNavigationBarItem(
      icon: Icon(Icons.people_outline),
      activeIcon: Icon(Icons.people),
      label: 'Contacts',
    ),
    BottomNavigationBarItem(
      icon: Icon(Icons.key_outlined),
      activeIcon: Icon(Icons.key),
      label: 'Identity',
    ),
    BottomNavigationBarItem(
      icon: Icon(Icons.cell_tower_outlined),
      activeIcon: Icon(Icons.cell_tower),
      label: 'Network',
    ),
    BottomNavigationBarItem(
      icon: Icon(Icons.info_outline),
      activeIcon: Icon(Icons.info),
      label: 'About',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Consumer3<TorManager, CoreBridge, NetworkService>(
      builder: (context, tor, bridge, network, _) {
        // Update identity's onion address when Tor connects
        _updateOnionAddress(context, tor);
        
        return Scaffold(
          body: Column(
            children: [
              // Embedded Tor status banner
              _TorStatusBanner(tor: tor),
              
              // Kill-switch warning: Tor not connected
              if (tor.status.state != TorState.connected)
                WarningBanner(
                  text: 'Tor not connected. '
                      'All messaging is suspended (kill-switch active).',
                  color: AppTheme.error,
                  icon: Icons.shield_outlined,
                ),
                
              // Note: Core process warning removed - using standalone Dart crypto

              // Main content
              Expanded(child: _screens[_selectedIndex]),
            ],
          ),
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: _selectedIndex,
            onTap: (index) => setState(() => _selectedIndex = index),
            items: _navItems,
            type: BottomNavigationBarType.fixed,
            backgroundColor: AppTheme.surface,
            selectedItemColor: AppTheme.primary,
            unselectedItemColor: AppTheme.textSecondary,
            showUnselectedLabels: true,
            selectedFontSize: 11,
            unselectedFontSize: 11,
          ),
        );
      },
    );
  }
  
  /// Update the identity service with the onion address from Tor
  void _updateOnionAddress(BuildContext context, TorManager tor) {
    // Only update once when Tor connects and we haven't updated yet
    if (tor.status.isConnected && !_onionAddressUpdated) {
      _onionAddressUpdated = true;
      
      // Fetch onion address asynchronously
      tor.getOnionAddress().then((onionAddress) {
        if (onionAddress != null && onionAddress.isNotEmpty) {
          final identityService = context.read<IdentityService>();
          identityService.updateOnionAddress(onionAddress);
          debugPrint('HomeScreen: Updated identity with onion address: $onionAddress');
        }
      });
    } else if (!tor.status.isConnected) {
      // Reset flag if Tor disconnects so we can update again
      _onionAddressUpdated = false;
    }
  }
}

/// Tor status banner with bootstrap progress
class _TorStatusBanner extends StatelessWidget {
  final TorManager tor;

  const _TorStatusBanner({required this.tor});

  @override
  Widget build(BuildContext context) {
    final status = tor.status;
    
    // Don't show banner when fully connected
    if (status.state == TorState.connected) {
      return const SizedBox.shrink();
    }
    
    Color backgroundColor;
    IconData icon;
    
    switch (status.state) {
      case TorState.stopped:
        backgroundColor = AppTheme.error;
        icon = Icons.power_off;
      case TorState.starting:
      case TorState.connecting:
        backgroundColor = AppTheme.warning;
        icon = Icons.sync;
      case TorState.connected:
        backgroundColor = AppTheme.success;
        icon = Icons.check_circle;
      case TorState.error:
        backgroundColor = AppTheme.error;
        icon = Icons.error;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: backgroundColor,
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tor.statusText,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (status.state == TorState.connecting) ...[
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: status.bootstrapProgress / 100,
                        backgroundColor: Colors.white24,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Colors.white,
                        ),
                        minHeight: 4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

