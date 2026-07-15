import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/messaging_service.dart';
import '../services/contacts_service.dart';
import '../services/network_service.dart';
import '../services/tor_manager.dart';
import '../models/message.dart';
import '../models/delivery_status.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';

/// Chat Screen (Screen 3)
///
/// Displays:
/// - Text input
/// - Voice message recording (async only)
/// - Delivery ticks only (✓ / ✓✓)
/// - No timestamps beyond coarse ordering
///
/// Explicitly ABSENT:
/// - Typing indicators
/// - Read receipts
/// - Online status
/// - Last seen
/// - Message timestamps
///
/// Kill-switch: Messaging blocked unless embedded Tor is connected.
class ChatScreen extends StatefulWidget {
  final String contactId;

  const ChatScreen({super.key, required this.contactId});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  int _recordingDuration = 0;
  Timer? _recordingTimer;
  String? _recordedPath;
  bool _isTextEmpty = true;

  @override
  void initState() {
    super.initState();
    _textController.addListener(_onTextChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final messaging = context.read<MessagingService>();
      messaging.loadMessages(widget.contactId).then((_) {
        messaging.markAsRead(widget.contactId);
      });
    });
  }

  void _onTextChanged() {
    final isNowEmpty = _textController.text.trim().isEmpty;
    if (isNowEmpty != _isTextEmpty) {
      setState(() {
        _isTextEmpty = isNowEmpty;
      });
    }
  }

  @override
  void dispose() {
    _textController.removeListener(_onTextChanged);
    _textController.dispose();
    _scrollController.dispose();
    _audioRecorder.dispose();
    _recordingTimer?.cancel();
    super.dispose();
  }

  Future<void> _startRecording() async {
    try {
      if (await Permission.microphone.request().isGranted) {
        final directory = await getTemporaryDirectory();
        final path = '${directory.path}/temp_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';

        await _audioRecorder.start(
          const RecordConfig(
            encoder: AudioEncoder.aacLc,
            sampleRate: 16000,
            bitRate: 16000,
            numChannels: 1,
          ),
          path: path,
        );

        _recordedPath = null;
        setState(() {
          _isRecording = true;
          _recordingDuration = 0;
        });

        _recordingTimer?.cancel();
        _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
          setState(() {
            _recordingDuration++;
          });

          // Check actual file size on disk dynamically to prevent transport size violation
          try {
            final file = File(path);
            if (await file.exists()) {
              final size = await file.length();
              if (size > 28000) {
                timer.cancel();
                await _stopRecordingState();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Recording limit reached (file size limit to fit secure transport).'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
                return;
              }
            }
          } catch (e) {
            debugPrint('Failed to check recording file size: $e');
          }
          
          if (_recordingDuration >= 15) {
            timer.cancel();
            await _stopRecordingState();
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Recording limit reached (15s max to fit secure transport).'),
                  duration: Duration(seconds: 2),
                ),
              );
            }
          }
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission denied.')),
        );
      }
    } catch (e) {
      debugPrint('Failed to start recording: $e');
    }
  }

  Future<void> _stopRecordingState() async {
    try {
      _recordingTimer?.cancel();
      final path = await _audioRecorder.stop();
      setState(() {
        _isRecording = false;
        _recordedPath = path;
      });
    } catch (e) {
      debugPrint('Failed to stop recording: $e');
    }
  }

  Future<void> _cancelRecording() async {
    try {
      _recordingTimer?.cancel();
      final path = await _audioRecorder.stop();
      final actualPath = path ?? _recordedPath;
      if (actualPath != null && actualPath.isNotEmpty) {
        final file = File(actualPath);
        if (await file.exists()) {
          await file.delete();
        }
      }
    } catch (e) {
      debugPrint('Failed to cancel recording: $e');
    }
    setState(() {
      _isRecording = false;
      _recordedPath = null;
      _recordingDuration = 0;
    });
  }

  Future<void> _sendRecordedVoice() async {
    _recordingTimer?.cancel();
    String? path = _recordedPath;
    if (_isRecording) {
      path = await _audioRecorder.stop();
    }
    
    setState(() {
      _isRecording = false;
      _recordedPath = null;
      _recordingDuration = 0;
    });

    if (path != null && path.isNotEmpty) {
      final contact = context.read<ContactsService>().getContact(widget.contactId);
      if (contact != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sending voice message...')),
        );

        final sent = await context.read<MessagingService>().sendVoiceMessage(
          contactId: widget.contactId,
          filePath: path,
          contact: contact,
        );

        if (!sent && mounted) {
          final error = context.read<MessagingService>().error ?? 'Failed to send voice message.';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(error)),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final contact =
        context.read<ContactsService>().getContact(widget.contactId);
    final contactLabel = contact?.label ?? 'Unknown';

    return Consumer3<TorManager, MessagingService, NetworkService>(
      builder: (context, tor, messaging, network, _) {
        final messages = messaging.getMessages(widget.contactId);

        // Mark messages as read dynamically when new ones arrive
        WidgetsBinding.instance.addPostFrameCallback((_) {
          messaging.markAsRead(widget.contactId);
        });

        // Kill-switch: Use embedded Tor status
        final torConnected = tor.status.isConnected;

        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(contactLabel, style: const TextStyle(fontSize: 16)),
                Row(
                  children: [
                    StatusDot(
                      color: torConnected
                          ? AppTheme.success
                          : AppTheme.error,
                      size: 6,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      torConnected ? 'Tor connected' : tor.statusText,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              // Contact info
              IconButton(
                icon: const Icon(Icons.fingerprint, size: 20),
                tooltip: 'Contact fingerprint',
                onPressed: () =>
                    _showContactFingerprint(context, contact),
              ),
            ],
          ),
          body: Column(
            children: [
              // Tor disconnect warning
              if (!torConnected)
                WarningBanner(
                  text: 'Tor disconnected. Messages cannot be sent '
                      'or received. Kill-switch is active.',
                  color: AppTheme.error,
                  icon: Icons.shield_outlined,
                ),

              // Unverified contact warning
              if (contact != null && !contact.isVerified)
                WarningBanner(
                  text: 'Contact fingerprint not verified. '
                      'Verify in person or via secure channel.',
                  color: AppTheme.warning,
                  icon: Icons.warning_amber_rounded,
                ),

              // Message list
              Expanded(
                child: messages.isEmpty
                    ? _buildEmptyChat(context)
                    : _buildMessageList(messages),
              ),

              // Input area
              _buildInputArea(context, messaging, torConnected),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyChat(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_outline, size: 48,
                color: AppTheme.textSecondary),
            const SizedBox(height: 16),
            Text(
              'End-to-End Encrypted',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Messages are encrypted with the Signal Double Ratchet '
              'protocol and routed through 3+ onion layers over Tor.\n\n'
              'Messages may take 3–10 seconds to deliver. '
              'This is by design.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  List<dynamic> _groupMessagesWithSeparators(List<Message> messages) {
    final List<dynamic> items = [];
    if (messages.isEmpty) return items;

    // Iterate from oldest to newest to insert separators when dates change
    DateTime? lastDate;
    for (final message in messages) {
      final isoStr = message.localReceivedAt;
      if (isoStr == null || isoStr.isEmpty) {
        items.add(message);
        continue;
      }
      try {
        final date = DateTime.parse(isoStr).toLocal();
        final currentDate = DateTime(date.year, date.month, date.day);
        
        if (lastDate == null || currentDate != lastDate) {
          items.add(currentDate);
          lastDate = currentDate;
        }
      } catch (_) {}
      items.add(message);
    }
    
    // Reverse because the ListView.builder has reverse: true
    return items.reversed.toList();
  }

  Widget _buildDateSeparator(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    
    String text;
    if (date == today) {
      text = 'Today';
    } else if (date == yesterday) {
      text = 'Yesterday';
    } else {
      text = '${date.day}/${date.month}/${date.year}';
    }
    
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withOpacity(0.06)),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            color: AppTheme.textSecondary,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildMessageList(List<Message> messages) {
    final groupedItems = _groupMessagesWithSeparators(messages);

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: groupedItems.length,
      reverse: true,
      itemBuilder: (context, index) {
        final item = groupedItems[index];
        if (item is DateTime) {
          return _buildDateSeparator(item);
        } else if (item is Message) {
          return _MessageBubble(message: item);
        }
        return const SizedBox.shrink();
      },
    );
  }

  Widget _buildInputArea(
    BuildContext context,
    MessagingService messaging,
    bool torConnected,
  ) {
    if (_isRecording) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          border: Border(
            top: BorderSide(color: Colors.white.withOpacity(0.06)),
          ),
        ),
        child: SafeArea(
          child: Row(
            children: [
              IconButton(
                icon: Icon(Icons.delete_outline, color: AppTheme.error),
                tooltip: 'Discard recording',
                onPressed: _cancelRecording,
              ),
              const SizedBox(width: 8),
              Text(
                '0:${_recordingDuration.toString().padLeft(2, '0')}',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 12),
              const _PulsingDot(),
              const SizedBox(width: 8),
              const Expanded(
                child: Center(
                  child: _RecordingWaveform(),
                ),
              ),
              IconButton(
                icon: Icon(Icons.stop_circle_rounded, color: AppTheme.error, size: 28),
                tooltip: 'Stop and preview',
                onPressed: _stopRecordingState,
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _sendRecordedVoice,
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.send_rounded,
                    color: Colors.black,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_recordedPath != null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          border: Border(
            top: BorderSide(color: Colors.white.withOpacity(0.06)),
          ),
        ),
        child: SafeArea(
          child: Row(
            children: [
              IconButton(
                icon: Icon(Icons.delete_outline, color: AppTheme.error),
                tooltip: 'Discard recording',
                onPressed: () async {
                  if (_recordedPath != null) {
                    final file = File(_recordedPath!);
                    if (await file.exists()) {
                      await file.delete();
                    }
                    setState(() {
                      _recordedPath = null;
                    });
                  }
                },
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _VoicePreviewPlayer(filePath: _recordedPath!),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: _sendRecordedVoice,
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.send_rounded,
                    color: Colors.black,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border(
          top: BorderSide(color: Colors.white.withOpacity(0.06)),
        ),
      ),
      child: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Text input (takes full width)
            Expanded(
              child: TextField(
                controller: _textController,
                maxLines: 5,
                minLines: 1,
                enabled: torConnected,
                decoration: InputDecoration(
                  hintText: torConnected
                      ? 'Message...'
                      : 'Tor disconnected — messaging suspended',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: Colors.white.withOpacity(0.05),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
              ),
            ),

            const SizedBox(width: 4),

            // Swapped Right Button (Mic if empty, Send if typed)
            if (_isTextEmpty)
              IconButton(
                icon: Icon(
                  Icons.mic_outlined,
                  color: AppTheme.primary,
                ),
                tooltip: 'Voice message (async)',
                onPressed: torConnected ? _startRecording : null,
              )
            else
              IconButton(
                icon: Icon(Icons.send_rounded, color: AppTheme.primary),
                onPressed: torConnected ? () => _sendMessage(messaging) : null,
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendMessage(MessagingService messaging) async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    // Clear input area immediately for responsive feel
    _textController.clear();

    // Scroll to bottom immediately
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0.0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }

    final contact = context.read<ContactsService>().getContact(widget.contactId);
    if (contact == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Contact not found')),
      );
      return;
    }

    final network = context.read<NetworkService>();
    final mailbox = network.status.mailbox;

    final ready = await messaging.ensureInitialized(
      mailboxAddress: mailbox?.address ?? '',
      mailboxPort: mailbox?.port ?? 80,
    );

    if (!ready) {
      final error = messaging.error ?? 'Messaging is not ready yet.';
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
      return;
    }

    final sent = await messaging.sendTextMessage(
      contactId: widget.contactId,
      text: text,
      contact: contact,
    );

    if (!mounted) return;

    if (!sent) {
      final error = messaging.error ?? 'Failed to send message.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
      return;
    }

  }

  // Recording state managed directly via _startRecording, _stopRecordingState, etc.

  void _showContactFingerprint(BuildContext context, dynamic contact) {
    if (contact == null) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Row(
          children: [
            const Icon(Icons.fingerprint),
            const SizedBox(width: 8),
            Text(contact.label),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Verify this fingerprint with your contact:'),
            const SizedBox(height: 12),
            MonospaceText(text: contact.formattedFingerprint),
            const SizedBox(height: 16),
            Text(
              contact.isVerified
                  ? '✓ Fingerprint verified'
                  : '⚠ Fingerprint NOT yet verified',
              style: TextStyle(
                color: contact.isVerified
                    ? AppTheme.success
                    : AppTheme.warning,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        actions: [
          if (!contact.isVerified)
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                final contactsService =
                    Provider.of<ContactsService>(context, listen: false);
                await contactsService.verifyContact(contact.id);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text('Contact identity verified successfully!'),
                      backgroundColor: AppTheme.success,
                    ),
                  );
                }
              },
              child: const Text('Verify Identity', style: TextStyle(color: Color(0xFF00E676))),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

/// A single message bubble.
///
/// Displays text or voice indicator, plus delivery tick.
/// NO timestamps — only coarse ordering via list position.
class _MessageBubble extends StatelessWidget {
  final Message message;

  const _MessageBubble({required this.message});

  String _formatBubbleTime(String? isoString) {
    if (isoString == null || isoString.isEmpty) return '';
    try {
      final dateTime = DateTime.parse(isoString).toLocal();
      final hour = dateTime.hour > 12
          ? dateTime.hour - 12
          : (dateTime.hour == 0 ? 12 : dateTime.hour);
      final amPm = dateTime.hour >= 12 ? 'pm' : 'am';
      final minute = dateTime.minute.toString().padLeft(2, '0');
      return '$hour:$minute $amPm';
    } catch (e) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isOutgoing = message.isOutgoing;

    return Align(
      alignment: isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isOutgoing
              ? AppTheme.primary.withOpacity(0.15)
              : AppTheme.surface,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isOutgoing ? 16 : 4),
            bottomRight: Radius.circular(isOutgoing ? 4 : 16),
          ),
          border: Border.all(
            color: Colors.white.withOpacity(0.06),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message.type == MessageType.text &&
                message.textContent != null)
              Text(
                message.textContent!,
                style: const TextStyle(fontSize: 15),
              )
            else if (message.type == MessageType.voice)
              message.voiceDataPath != null
                  ? _VoicePlayer(filePath: message.voiceDataPath!)
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.mic, size: 16, color: AppTheme.error),
                        const SizedBox(width: 6),
                        const Text('Voice Message (File Missing)',
                            style: TextStyle(fontSize: 14)),
                      ],
                    ),

            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _formatBubbleTime(message.localReceivedAt),
                  style: TextStyle(
                    fontSize: 10,
                    color: AppTheme.textSecondary,
                  ),
                ),
                if (isOutgoing) ...[
                  const SizedBox(width: 4),
                  Text(
                    message.deliveryStatus.displayTick,
                    style: TextStyle(
                      fontSize: 11,
                      color: message.deliveryStatus == DeliveryStatus.failed
                          ? AppTheme.error
                          : AppTheme.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _VoicePlayer extends StatefulWidget {
  final String filePath;

  const _VoicePlayer({required this.filePath});

  @override
  State<_VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<_VoicePlayer> {
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isPlaying = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  StreamSubscription? _durationSub;
  StreamSubscription? _positionSub;
  StreamSubscription? _completeSub;

  @override
  void initState() {
    super.initState();
    _durationSub = _audioPlayer.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _positionSub = _audioPlayer.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _completeSub = _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _position = Duration.zero;
        });
      }
    });

    // Preload source to fetch metadata and display the audio duration immediately
    _audioPlayer.setSource(DeviceFileSource(widget.filePath)).catchError((e) {
      debugPrint('Failed to pre-set player source: $e');
    });
  }

  @override
  void dispose() {
    _durationSub?.cancel();
    _positionSub?.cancel();
    _completeSub?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _playPause() async {
    try {
      if (_isPlaying) {
        await _audioPlayer.pause();
        if (mounted) setState(() => _isPlaying = false);
      } else {
        await _audioPlayer.play(DeviceFileSource(widget.filePath));
        if (mounted) setState(() => _isPlaying = true);
      }
    } catch (e) {
      debugPrint('Failed to play audio: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final durationText = _formatDuration(_position) + ' / ' + _formatDuration(_duration);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(
            _isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
            size: 32,
            color: AppTheme.primary,
          ),
          constraints: const BoxConstraints(),
          padding: EdgeInsets.zero,
          onPressed: _playPause,
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 140,
              height: 12,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2.0,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5.0),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 10.0),
                  activeTrackColor: AppTheme.primary,
                  inactiveTrackColor: Colors.white12,
                  thumbColor: AppTheme.primary,
                ),
                child: Slider(
                  min: 0.0,
                  max: _duration.inMilliseconds.toDouble() > 0 
                      ? _duration.inMilliseconds.toDouble() 
                      : 1.0,
                  value: _position.inMilliseconds.toDouble().clamp(
                        0.0,
                        _duration.inMilliseconds.toDouble() > 0 
                            ? _duration.inMilliseconds.toDouble() 
                            : 1.0,
                      ),
                  onChanged: (val) async {
                    await _audioPlayer.seek(Duration(milliseconds: val.toInt()));
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 6.0),
              child: Text(
                durationText,
                style: TextStyle(fontSize: 10, color: AppTheme.textSecondary),
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.2, end: 1.0).animate(_controller),
      child: Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
          color: Colors.red,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _RecordingWaveform extends StatefulWidget {
  const _RecordingWaveform();

  @override
  State<_RecordingWaveform> createState() => _RecordingWaveformState();
}

class _RecordingWaveformState extends State<_RecordingWaveform>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  final List<double> _heights = [12, 24, 8, 18, 14, 22, 10, 16, 20, 12, 6, 14];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(_heights.length, (index) {
            final double value = _controller.value;
            final double height = _heights[index] * (0.4 + 0.6 * value);
            return Container(
              width: 3,
              height: height,
              margin: const EdgeInsets.symmetric(horizontal: 1.5),
              decoration: BoxDecoration(
                color: AppTheme.textSecondary.withOpacity(0.6),
                borderRadius: BorderRadius.circular(1.5),
              ),
            );
          }),
        );
      },
    );
  }
}

class _VoicePreviewPlayer extends StatefulWidget {
  final String filePath;

  const _VoicePreviewPlayer({required this.filePath});

  @override
  State<_VoicePreviewPlayer> createState() => _VoicePreviewPlayerState();
}

class _VoicePreviewPlayerState extends State<_VoicePreviewPlayer> {
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isPlaying = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  StreamSubscription? _durationSub;
  StreamSubscription? _positionSub;
  StreamSubscription? _completeSub;

  @override
  void initState() {
    super.initState();
    _durationSub = _audioPlayer.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _positionSub = _audioPlayer.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _completeSub = _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _position = Duration.zero;
        });
      }
    });

    // Preload source to fetch metadata and display the audio duration immediately
    _audioPlayer.setSource(DeviceFileSource(widget.filePath)).catchError((e) {
      debugPrint('Failed to pre-set player source: $e');
    });
  }

  @override
  void dispose() {
    _durationSub?.cancel();
    _positionSub?.cancel();
    _completeSub?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _playPause() async {
    try {
      if (_isPlaying) {
        await _audioPlayer.pause();
        if (mounted) setState(() => _isPlaying = false);
      } else {
        await _audioPlayer.play(DeviceFileSource(widget.filePath));
        if (mounted) setState(() => _isPlaying = true);
      }
    } catch (e) {
      debugPrint('Failed to play audio: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final durationText = _formatDuration(_position) + ' / ' + _formatDuration(_duration);

    return Row(
      children: [
        IconButton(
          icon: Icon(
            _isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
            size: 32,
            color: AppTheme.primary,
          ),
          constraints: const BoxConstraints(),
          padding: EdgeInsets.zero,
          onPressed: _playPause,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2.0,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5.0),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 10.0),
              activeTrackColor: AppTheme.primary,
              inactiveTrackColor: Colors.white12,
              thumbColor: AppTheme.primary,
            ),
            child: Slider(
              min: 0.0,
              max: _duration.inMilliseconds.toDouble() > 0 
                  ? _duration.inMilliseconds.toDouble() 
                  : 1.0,
              value: _position.inMilliseconds.toDouble().clamp(
                    0.0,
                    _duration.inMilliseconds.toDouble() > 0 
                        ? _duration.inMilliseconds.toDouble() 
                        : 1.0,
                  ),
              onChanged: (val) async {
                await _audioPlayer.seek(Duration(milliseconds: val.toInt()));
              },
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          durationText,
          style: TextStyle(fontSize: 10, color: AppTheme.textSecondary),
        ),
      ],
    );
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

