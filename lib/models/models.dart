/// Data models for the Secure Insta Message Flutter client.
///
/// These models represent the data structures exchanged between
/// the Flutter UI and the Python core via JSON-RPC.
///
/// IMPORTANT: These are presentation models only. They do not
/// contain any protocol logic, cryptographic operations, or
/// security-critical code. All such logic lives in the Python core.
library models;

export 'identity.dart';
export 'contact.dart';
export 'message.dart';
export 'network_status.dart';
export 'delivery_status.dart';
export 'core_command.dart';
export 'core_response.dart';

