import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../services/contacts_service.dart';
import '../services/network_service.dart';
import '../services/messaging_service.dart';
import '../models/contact.dart';
import '../models/message.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';
import 'chat_screen.dart';

/// Contacts Screen (Screen 2)
///
/// Manages contacts with:
/// - Manual public key exchange
/// - Fingerprint verification status
/// - Manual trust confirmation
///
/// NO contact syncing, NO phone book access, NO auto-discovery.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  ContactsService? _contactsService;
  List<Contact> _contacts = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _contactsService ??= context.read<ContactsService>();
    if (_isLoading) {
      _loadContacts();
    }
  }

  Future<void> _loadContacts() async {
    final service = _contactsService;
    if (service == null) return;

    await service.loadContacts();
    if (mounted) {
      final messaging = context.read<MessagingService>();
      for (final contact in service.contacts) {
        await messaging.loadMessages(contact.id);
      }
      setState(() {
        _contacts = service.contacts.toList();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Contacts'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_outlined),
            tooltip: 'Add Contact',
            onPressed: () => _showAddContactDialog(context),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _contacts.isEmpty
              ? _buildEmptyState(context)
              : _buildContactList(context),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.people_outline,
              size: 64,
              color: AppTheme.textSecondary,
            ),
            const SizedBox(height: 16),
            Text(
              'No Contacts',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Add a contact by exchanging public keys and onion '
              'addresses through an out-of-band channel.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              icon: const Icon(Icons.person_add_outlined, size: 18),
              label: const Text('Add Contact'),
              onPressed: () => _showAddContactDialog(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContactList(BuildContext context) {
    return Consumer<MessagingService>(
      builder: (context, messaging, _) {
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: _contacts.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final contact = _contacts[index];
            final unreadCount = messaging.getUnreadCount(contact.id);
            final lastMessage = messaging.getLastMessage(contact.id);
            return _ContactTile(
              contact: contact,
              unreadCount: unreadCount,
              lastMessage: lastMessage,
              onTap: () => _openChat(context, contact),
              onVerify: () => _verifyContact(contact.id),
              onRemove: () => _confirmRemove(context, contact),
            );
          },
        );
      },
    );
  }

  void _openChat(BuildContext context, Contact contact) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(contactId: contact.id),
      ),
    );
  }

  Future<void> _verifyContact(String contactId) async {
    final service = _contactsService;
    if (service == null) return;

    await service.verifyContact(contactId);
    await _loadContacts();
  }

  void _confirmRemove(
    BuildContext context,
    Contact contact,
  ) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Remove Contact'),
        content: Text(
          'Remove "${contact.label}"? '
          'Message history will be securely deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              final service = _contactsService;
              if (service == null) return;
              await service.removeContact(contact.id);
              if (context.mounted) {
                await context.read<MessagingService>().removeContact(contact.id);
              }
              await _loadContacts();
            },
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddContactDialog(BuildContext screenContext) async {
    final request = await showDialog<_AddContactRequest>(
      context: screenContext,
      builder: (_) => const _AddContactDialog(),
    );

    if (request == null || !mounted) return;

    await _addContactAndRefresh(
      label: request.label,
      publicKey: request.publicKey,
      onionAddress: request.onionAddress,
      mailboxId: request.mailboxId,
    );
  }

  Future<void> _addContactAndRefresh({
    required String label,
    required String publicKey,
    required String onionAddress,
    required String mailboxId,
  }) async {
    final service = _contactsService;
    if (service == null) return;

    await service.addContact(
      label: label,
      publicKey: publicKey,
      onionAddress: onionAddress,
      mailboxId: mailboxId,
    );

    if (!mounted) return;
    
    try {
      final newContact = service.contacts.firstWhere((c) => c.mailboxId == mailboxId);
      await context.read<MessagingService>().registerContact(newContact);
    } catch (e) {
      debugPrint('ContactsScreen: Failed to register new contact with messaging service: $e');
    }
    
    await _loadContacts();
  }
}

class _AddContactRequest {
  final String label;
  final String publicKey;
  final String onionAddress;
  final String mailboxId;

  const _AddContactRequest({
    required this.label,
    required this.publicKey,
    required this.onionAddress,
    required this.mailboxId,
  });
}

class _AddContactDialog extends StatefulWidget {
  const _AddContactDialog();

  @override
  State<_AddContactDialog> createState() => _AddContactDialogState();
}

class _AddContactDialogState extends State<_AddContactDialog> {
  final TextEditingController _labelCtrl = TextEditingController();
  final TextEditingController _keyCtrl = TextEditingController();
  final TextEditingController _onionCtrl = TextEditingController();
  final TextEditingController _mailboxCtrl = TextEditingController();

  @override
  void dispose() {
    _labelCtrl.dispose();
    _keyCtrl.dispose();
    _onionCtrl.dispose();
    _mailboxCtrl.dispose();
    super.dispose();
  }

  Future<void> _scanQr() async {
    final result = await Navigator.of(context).push<Map<String, String>>(
      MaterialPageRoute(
        builder: (_) => const _QRScannerScreen(),
      ),
    );

    if (!mounted || result == null) return;
    if (result['public_key']?.isNotEmpty != true) return;

    final scannedPublicKey = result['public_key']?.trim() ?? '';
    final scannedOnion = result['onion_address']?.trim() ?? '';
    final scannedMailbox = result['mailbox_id']?.trim() ?? '';

    setState(() {
      _keyCtrl.text = scannedPublicKey;
      _onionCtrl.text = scannedOnion;
      _mailboxCtrl.text = scannedMailbox;
    });
  }

  void _submitManual() {
    if (_labelCtrl.text.isEmpty || _keyCtrl.text.isEmpty) {
      return;
    }

    Navigator.of(context).pop(
      _AddContactRequest(
        label: _labelCtrl.text.trim(),
        publicKey: _keyCtrl.text.trim(),
        onionAddress: _onionCtrl.text.trim(),
        mailboxId: _mailboxCtrl.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.surface,
      title: const Text('Add Contact'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Scan their QR code or enter details manually.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.qr_code_scanner, size: 20),
              label: const Text('Scan QR Code'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 48),
              ),
              onPressed: _scanQr,
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            Text(
              'Or enter manually:',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _labelCtrl,
              decoration: const InputDecoration(
                labelText: 'Label / Alias',
                hintText: 'Contact Name',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _keyCtrl,
              decoration: const InputDecoration(
                labelText: 'Public Key (hex)',
                hintText: 'Ed25519 public key',
              ),
              maxLines: 2,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _onionCtrl,
              decoration: const InputDecoration(
                labelText: 'Onion Address',
                hintText: 'xxxxx.onion',
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _mailboxCtrl,
              decoration: const InputDecoration(
                labelText: 'Mailbox ID (hex)',
                hintText: '32-byte random mailbox identifier',
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _submitManual,
          child: const Text('Add'),
        ),
      ],
    );
  }
}

/// QR Scanner screen for scanning contact identity QR codes.
class _QRScannerScreen extends StatefulWidget {
  const _QRScannerScreen();

  @override
  State<_QRScannerScreen> createState() => _QRScannerScreenState();
}

class _QRScannerScreenState extends State<_QRScannerScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _hasScanned = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_hasScanned) return;
    
    final barcode = capture.barcodes.firstOrNull;
    if (barcode?.rawValue == null) return;

    final rawValue = barcode!.rawValue!;
    _hasScanned = true;

    try {
      // Try to parse as JSON (our QR format)
      final decoded = utf8.decode(base64Decode(rawValue));
      final data = jsonDecode(decoded) as Map<String, dynamic>;

      final parsedOnion =
          (data['onion_address'] as String?) ??
          (data['onionAddress'] as String?) ??
          (data['onion'] as String?) ??
          '';
      
      Navigator.of(context).pop({
        'label': '', // User can fill in
        'public_key': data['public_key'] as String? ?? '',
        'onion_address': parsedOnion,
        'fingerprint': data['fingerprint'] as String? ?? '',
        'mailbox_id': data['mailbox_id'] as String? ?? '',
      });
    } catch (e) {
      // Maybe it's just a raw public key
      if (rawValue.length == 64 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(rawValue)) {
        Navigator.of(context).pop({
          'label': '',
          'public_key': rawValue,
          'onion_address': '',
          'mailbox_id': '',
        });
      } else {
        // Unknown format - show error and allow retry
        _hasScanned = false;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid QR code format')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan QR Code'),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on),
            onPressed: () => _controller.toggleTorch(),
          ),
          IconButton(
            icon: const Icon(Icons.cameraswitch),
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
            ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            color: AppTheme.surface,
            child: Text(
              'Point camera at the contact\'s identity QR code',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

/// A single contact row.
class _ContactTile extends StatelessWidget {
  final Contact contact;
  final int unreadCount;
  final Message? lastMessage;
  final VoidCallback onTap;
  final VoidCallback onVerify;
  final VoidCallback onRemove;

  const _ContactTile({
    required this.contact,
    required this.unreadCount,
    required this.lastMessage,
    required this.onTap,
    required this.onVerify,
    required this.onRemove,
  });

  String _formatMessageTime(String? isoString) {
    if (isoString == null || isoString.isEmpty) return '';
    try {
      final dateTime = DateTime.parse(isoString).toLocal();
      final now = DateTime.now();
      
      final todayStart = DateTime(now.year, now.month, now.day);
      final yesterdayStart = todayStart.subtract(const Duration(days: 1));
      final sixDaysAgoStart = todayStart.subtract(const Duration(days: 6));
      
      final msgDate = DateTime(dateTime.year, dateTime.month, dateTime.day);
      
      // Today: time (e.g., 8:20 am)
      if (msgDate == todayStart) {
        final hour = dateTime.hour > 12
            ? dateTime.hour - 12
            : (dateTime.hour == 0 ? 12 : dateTime.hour);
        final amPm = dateTime.hour >= 12 ? 'pm' : 'am';
        final minute = dateTime.minute.toString().padLeft(2, '0');
        return '$hour:$minute $amPm';
      }
      
      // Yesterday: Yesterday
      if (msgDate == yesterdayStart) {
        return 'Yesterday';
      }
      
      // Within last 7 days (exclusive of today/yesterday): day name (e.g., Monday)
      if (msgDate.isAfter(sixDaysAgoStart)) {
        const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
        return days[dateTime.weekday - 1];
      }
      
      // Older than 7 days: date (e.g., 15/07/26)
      final dayStr = dateTime.day.toString().padLeft(2, '0');
      final monthStr = dateTime.month.toString().padLeft(2, '0');
      final yearStr = dateTime.year.toString().substring(2);
      return '$dayStr/$monthStr/$yearStr';
    } catch (e) {
      return '';
    }
  }

  Widget? _buildSubtitle() {
    final msg = lastMessage;
    if (msg == null) {
      return Text(
        contact.formattedFingerprint.isEmpty
            ? 'No fingerprint'
            : contact.formattedFingerprint.substring(
                0,
                contact.formattedFingerprint.length > 24
                    ? 24
                    : contact.formattedFingerprint.length,
              ),
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 11,
          color: AppTheme.textSecondary,
        ),
      );
    }

    if (msg.type == MessageType.voice) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.mic, size: 14, color: AppTheme.textSecondary),
          const SizedBox(width: 4),
          Text(
            'Voice Message',
            style: TextStyle(
              fontSize: 13,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      );
    }

    return Text(
      msg.textContent ?? '',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 13,
        color: AppTheme.textSecondary,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: AppTheme.surface,
        child: Icon(
          contact.isVerified
              ? Icons.verified_user
              : Icons.person_outline,
          color: contact.isVerified
              ? AppTheme.success
              : AppTheme.textSecondary,
        ),
      ),
      title: Text(contact.label),
      subtitle: _buildSubtitle(),
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (lastMessage != null) ...[
            Text(
              _formatMessageTime(lastMessage!.localReceivedAt),
              style: TextStyle(
                color: unreadCount > 0
                    ? AppTheme.primary
                    : AppTheme.textSecondary,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 4),
          ],
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!contact.isVerified) ...[
                IconButton(
                  icon: Icon(Icons.verified_outlined,
                      color: AppTheme.warning, size: 18),
                  tooltip: 'Verify fingerprint',
                  constraints: const BoxConstraints(),
                  padding: EdgeInsets.zero,
                  onPressed: onVerify,
                ),
                const SizedBox(width: 6),
              ],
              if (unreadCount > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '$unreadCount',
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                )
              else if (contact.hasSession)
                StatusDot(color: AppTheme.success)
              else
                StatusDot(color: AppTheme.textSecondary),
            ],
          ),
        ],
      ),
      onTap: onTap,
      onLongPress: onRemove,
    );
  }
}

