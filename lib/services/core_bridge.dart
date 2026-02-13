import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/core_command.dart';
import '../models/core_response.dart';

/// Bridge to the Python core process.
///
/// Communicates via JSON-RPC over stdin/stdout with the Python
/// core subprocess. This is the ONLY interface between Flutter
/// and the protocol implementation.
///
/// Architecture:
///   Flutter UI → CoreBridge → Python Core (subprocess)
///
/// The bridge:
///   - Starts and manages the Python core process lifecycle
///   - Sends JSON-RPC commands to the core's stdin
///   - Reads JSON-RPC responses from the core's stdout
///   - Handles notifications (unsolicited events from core)
///   - Enforces that Flutter never bypasses this interface
///
/// The bridge does NOT:
///   - Implement any protocol logic
///   - Perform any cryptographic operations
///   - Make any network connections
///   - Handle key material
class CoreBridge extends ChangeNotifier {
  Process? _process;
  final _uuid = const Uuid();
  final _pendingRequests = <String, Completer<CoreResponse>>{};
  final _notificationController =
      StreamController<CoreResponse>.broadcast();
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  String _buffer = '';

  /// Whether the core process is running.
  bool get isRunning => _process != null;

  /// Stream of unsolicited notifications from core.
  Stream<CoreResponse> get notifications => _notificationController.stream;

  /// Connection state for UI display.
  CoreBridgeState _state = CoreBridgeState.disconnected;
  CoreBridgeState get state => _state;

  String? _lastError;
  String? get lastError => _lastError;

  /// Start the Python core process.
  ///
  /// [corePath] is the path to the Secure Insta Message core
  /// directory (the existing repo, unchanged).
  ///
  /// [pythonExecutable] defaults to 'python3' on Unix, 'python' on
  /// Windows. The core must already be installed with its
  /// requirements.txt.
  Future<bool> startCore({
    required String corePath,
    String? pythonExecutable,
    String? dataDir,
  }) async {
    if (_process != null) {
      return true; // Already running
    }

    _state = CoreBridgeState.connecting;
    _lastError = null;
    notifyListeners();

    final python = pythonExecutable ??
        (Platform.isWindows ? 'python' : 'python3');

    try {
      _process = await Process.start(
        python,
        [
          '-m',
          'src.bridge.flutter_bridge',
          if (dataDir != null) '--data-dir=$dataDir',
        ],
        workingDirectory: corePath,
        environment: {
          // Ensure Tor-only networking is enforced
          'SIM_TOR_ONLY': '1',
          'SIM_NO_CLEARNET': '1',
        },
      );

      // Listen to stdout for JSON-RPC responses
      _stdoutSubscription = _process!.stdout
          .transform(utf8.decoder)
          .listen(_onStdoutData);

      // Listen to stderr for errors (non-protocol, debug only)
      _stderrSubscription = _process!.stderr
          .transform(utf8.decoder)
          .listen(_onStderrData);

      // Handle process exit
      _process!.exitCode.then(_onProcessExit);

      _state = CoreBridgeState.connected;
      notifyListeners();
      return true;
    } catch (e) {
      _lastError = 'Failed to start core process: $e';
      _state = CoreBridgeState.error;
      notifyListeners();
      return false;
    }
  }

  /// Send a command to the Python core and await the response.
  ///
  /// Returns a [CoreResponse] with the result or error.
  /// Throws if the core process is not running.
  Future<CoreResponse> send({
    required String method,
    Map<String, dynamic> params = const {},
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (_process == null) {
      return CoreResponse(
        id: '',
        success: false,
        error: 'Core process is not running. '
            'The app cannot operate without the core.',
      );
    }

    final requestId = _uuid.v4();
    final command = CoreCommand(
      id: requestId,
      method: method,
      params: params,
    );

    final completer = Completer<CoreResponse>();
    _pendingRequests[requestId] = completer;

    try {
      _process!.stdin.writeln(command.toJsonString());
      await _process!.stdin.flush();
    } catch (e) {
      _pendingRequests.remove(requestId);
      return CoreResponse(
        id: requestId,
        success: false,
        error: 'Failed to send command to core: $e',
      );
    }

    // Await response with timeout
    try {
      return await completer.future.timeout(timeout, onTimeout: () {
        _pendingRequests.remove(requestId);
        return CoreResponse(
          id: requestId,
          success: false,
          error: 'Command timed out after ${timeout.inSeconds}s. '
              'This may indicate Tor connectivity issues.',
        );
      });
    } catch (e) {
      _pendingRequests.remove(requestId);
      return CoreResponse(
        id: requestId,
        success: false,
        error: 'Error awaiting response: $e',
      );
    }
  }

  /// Process stdout data from the core.
  void _onStdoutData(String data) {
    _buffer += data;

    // Process complete JSON lines
    while (_buffer.contains('\n')) {
      final newlineIndex = _buffer.indexOf('\n');
      final line = _buffer.substring(0, newlineIndex).trim();
      _buffer = _buffer.substring(newlineIndex + 1);

      if (line.isEmpty) continue;

      try {
        final json = jsonDecode(line) as Map<String, dynamic>;

        if (json.containsKey('id') && json['id'] != null) {
          // Response to a request
          final id = json['id'] as String;
          final completer = _pendingRequests.remove(id);
          if (completer != null) {
            completer.complete(CoreResponse.fromJsonString(line));
          }
        } else if (json.containsKey('method')) {
          // Notification (unsolicited event from core)
          _notificationController
              .add(CoreResponse.fromNotification(line));
        }
      } catch (e) {
        debugPrint('CoreBridge: Failed to parse response: $e');
      }
    }
  }

  /// Process stderr data from the core.
  void _onStderrData(String data) {
    // Stderr is for debugging only — never contains protocol data.
    // In production, this would be discarded.
    debugPrint('Core stderr: $data');
  }

  /// Handle core process exit.
  void _onProcessExit(int exitCode) {
    _process = null;
    _state = CoreBridgeState.disconnected;
    _lastError = exitCode != 0
        ? 'Core process exited with code $exitCode'
        : null;

    // Fail all pending requests
    for (final entry in _pendingRequests.entries) {
      entry.value.complete(CoreResponse(
        id: entry.key,
        success: false,
        error: 'Core process terminated',
      ));
    }
    _pendingRequests.clear();

    notifyListeners();
  }

  /// Stop the core process gracefully.
  Future<void> stopCore() async {
    if (_process == null) return;

    try {
      // Send shutdown command
      await send(method: 'shutdown');
    } catch (_) {
      // If graceful shutdown fails, kill the process
    }

    await Future.delayed(const Duration(seconds: 2));

    if (_process != null) {
      _process!.kill(ProcessSignal.sigterm);
      _process = null;
    }

    _state = CoreBridgeState.disconnected;
    notifyListeners();
  }

  /// Clean up resources.
  void dispose() {
    _stdoutSubscription?.cancel();
    _stderrSubscription?.cancel();
    _notificationController.close();
    _process?.kill();
    _process = null;
    super.dispose();
  }
}

/// State of the core bridge connection.
enum CoreBridgeState {
  disconnected,
  connecting,
  connected,
  error,
}

