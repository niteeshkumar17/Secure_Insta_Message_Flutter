/// Barrel export for all services.
///
/// ARCHITECTURE NOTE:
/// - message_server.dart has been DEPRECATED (security violation)
/// - All messaging now goes through:
///   - mailbox_client.dart (store-and-forward transport)
///   - cover_traffic_manager.dart (metadata resistance)
///   - ../crypto/ layer (E2E encryption)
library services;

export 'core_bridge.dart';
export 'identity_service.dart';
export 'contacts_service.dart';
export 'messaging_service.dart';
export 'network_service.dart';
export 'mailbox_client.dart';
export 'cover_traffic_manager.dart';
export 'tor_manager.dart';
export 'socks5_client.dart';

