import 'dart:convert';

/// A response received from the Python core via JSON-RPC.
class CoreResponse {
  /// The request ID this response correlates to.
  final String id;

  /// Whether the operation succeeded.
  final bool success;

  /// The result payload (if success).
  final Map<String, dynamic>? result;

  /// Error message (if failure).
  final String? error;

  /// Error code (if failure).
  final int? errorCode;

  const CoreResponse({
    required this.id,
    required this.success,
    this.result,
    this.error,
    this.errorCode,
  });

  factory CoreResponse.fromJsonString(String json) {
    final data = jsonDecode(json) as Map<String, dynamic>;
    final hasError = data.containsKey('error') && data['error'] != null;
    
    String? errorMessage;
    int? errorCode;
    
    if (hasError) {
      final errorData = data['error'] as Map<String, dynamic>?;
      errorMessage = errorData?['message'] as String?;
      errorCode = errorData?['code'] as int?;
    }
    
    return CoreResponse(
      id: (data['id'] ?? '') as String,
      success: !hasError,
      result: !hasError ? data['result'] as Map<String, dynamic>? : null,
      error: errorMessage,
      errorCode: errorCode,
    );
  }

  /// Parse a notification (no id, unsolicited event from core).
  factory CoreResponse.fromNotification(String json) {
    final data = jsonDecode(json) as Map<String, dynamic>;
    return CoreResponse(
      id: '',
      success: true,
      result: data['params'] as Map<String, dynamic>?,
    );
  }
}

