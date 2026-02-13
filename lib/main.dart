import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/core_bridge.dart';
import 'services/identity_service.dart';
import 'services/contacts_service.dart';
import 'services/messaging_service.dart';
import 'services/network_service.dart';
import 'services/tor_manager.dart';
import 'screens/home_screen.dart';
import 'theme/app_theme.dart';

/// Secure Insta Message — Flutter UI Client
///
/// This is a UI client for the Secure Insta Message protocol.
/// The reference implementation remains the CLI.
///
/// This app:
/// - Embeds Tor directly (no Orbot required)
/// - Delegates ALL crypto, onion routing, cover traffic, and
///   protocol logic to the existing Python core.
/// - Never implements cryptographic primitives.
/// - Never bypasses Tor (kill-switch enforced).
/// - Refuses to operate without Tor fully connected.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SecureInstaMessageApp());
}

class SecureInstaMessageApp extends StatefulWidget {
  const SecureInstaMessageApp({super.key});

  @override
  State<SecureInstaMessageApp> createState() => _SecureInstaMessageAppState();
}

class _SecureInstaMessageAppState extends State<SecureInstaMessageApp> {
  late final TorManager _torManager;
  late final CoreBridge _bridge;
  late final IdentityService _identityService;
  late final ContactsService _contactsService;
  late final MessagingService _messagingService;
  late final NetworkService _networkService;

  @override
  void initState() {
    super.initState();
    _torManager = TorManager();
    _bridge = CoreBridge();
    _identityService = IdentityService(_bridge);
    _contactsService = ContactsService(_bridge);
    _messagingService = MessagingService(_bridge);
    _networkService = NetworkService(_bridge);
    
    // Initialize TorManager (Tor auto-starts via native service)
    _torManager.initialize();
  }

  @override
  void dispose() {
    _torManager.dispose();
    _bridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _torManager),
        ChangeNotifierProvider.value(value: _bridge),
        ChangeNotifierProvider.value(value: _identityService),
        ChangeNotifierProvider.value(value: _contactsService),
        ChangeNotifierProvider.value(value: _messagingService),
        ChangeNotifierProvider.value(value: _networkService),
      ],
      child: MaterialApp(
        title: 'Secure Insta Message',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark,
        home: const HomeScreen(),
      ),
    );
  }
}

