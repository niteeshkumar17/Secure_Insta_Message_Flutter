import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/messaging_service.dart';
import '../services/contacts_service.dart';
import '../services/network_service.dart';
import '../services/tor_manager.dart';
import '../models/message.dart';
import '../models/delivery_status.dart';
import '../models/network_status.dart';
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
  bool _isRecording = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<MessagingService>().loadMessages(widget.contactId);
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final contact =
        context.read<ContactsService>().getContact(widget.contactId);
    final contactLabel = contact?.label ?? 'Unknown';

    return Consumer3<TorManager, MessagingService, NetworkService>(
      builder: (context, tor, messaging, network, _) {
        final messages = messaging.getMessages(widget.contactId);
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

  Widget _buildMessageList(List<Message> messages) {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: messages.length,
      reverse: false,
      itemBuilder: (context, index) {
        return _MessageBubble(message: messages[index]);
      },
    );
  }

  Widget _buildInputArea(
    BuildContext context,
    MessagingService messaging,
    bool torConnected,
  ) {
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
            // Voice message
            IconButton(
              icon: Icon(
                _isRecording ? Icons.stop_circle : Icons.mic_outlined,
                color: _isRecording ? AppTheme.error : AppTheme.textSecondary,
              ),
              tooltip: 'Voice message (async)',
              onPressed: torConnected ? _toggleRecording : null,
            ),

            // Text input
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

            // Send button
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

    _textController.clear();
    await messaging.sendTextMessage(
      contactId: widget.contactId,
      text: text,
    );

    // Scroll to bottom
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent + 80,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  void _toggleRecording() {
    setState(() => _isRecording = !_isRecording);

    if (!_isRecording) {
      // Recording stopped — would send voice message via core
      // Actual recording uses the record package and passes the
      // file path to MessagingService.sendVoiceMessage()
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Voice message recording finished. Sending...'),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Recording voice message (async only — no calls).',
          ),
        ),
      );
    }
  }

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
          children: [
            if (message.type == MessageType.text &&
                message.textContent != null)
              Text(
                message.textContent!,
                style: const TextStyle(fontSize: 15),
              )
            else if (message.type == MessageType.voice)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.mic, size: 16, color: AppTheme.primary),
                  const SizedBox(width: 6),
                  const Text('Voice Message',
                      style: TextStyle(fontSize: 14)),
                ],
              ),

            // Delivery tick (outgoing only)
            if (isOutgoing) ...[
              const SizedBox(height: 4),
              Text(
                message.deliveryStatus.displayTick,
                style: TextStyle(
                  fontSize: 12,
                  color: message.deliveryStatus == DeliveryStatus.failed
                      ? AppTheme.error
                      : AppTheme.textSecondary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

