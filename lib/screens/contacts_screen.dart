import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/contacts_service.dart';
import '../models/contact.dart';
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
  @override
  void initState() {
    super.initState();
    // Load contacts when screen opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ContactsService>().loadContacts();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ContactsService>(
      builder: (context, service, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Contacts'),
            actions: [
              IconButton(
                icon: const Icon(Icons.person_add_outlined),
                tooltip: 'Add Contact',
                onPressed: () => _showAddContactDialog(context, service),
              ),
            ],
          ),
          body: service.contacts.isEmpty
              ? _buildEmptyState(context)
              : _buildContactList(context, service),
        );
      },
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
              onPressed: () => _showAddContactDialog(
                context,
                context.read<ContactsService>(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContactList(
      BuildContext context, ContactsService service) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: service.contacts.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final contact = service.contacts[index];
        return _ContactTile(
          contact: contact,
          onTap: () => _openChat(context, contact),
          onVerify: () => service.verifyContact(contact.id),
          onRemove: () => _confirmRemove(context, service, contact),
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

  void _confirmRemove(
    BuildContext context,
    ContactsService service,
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
            onPressed: () {
              Navigator.of(ctx).pop();
              service.removeContact(contact.id);
            },
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  void _showAddContactDialog(
      BuildContext context, ContactsService service) {
    final labelCtrl = TextEditingController();
    final keyCtrl = TextEditingController();
    final onionCtrl = TextEditingController();
    final mailboxCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Add Contact'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Enter the contact\'s details obtained through a '
                'secure out-of-band channel.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: labelCtrl,
                decoration: const InputDecoration(
                  labelText: 'Label / Alias',
                  hintText: 'A name for this contact',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: keyCtrl,
                decoration: const InputDecoration(
                  labelText: 'Public Key (hex)',
                  hintText: 'Ed25519 public key',
                ),
                maxLines: 2,
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: onionCtrl,
                decoration: const InputDecoration(
                  labelText: 'Onion Address',
                  hintText: 'xxxxx.onion',
                ),
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: mailboxCtrl,
                decoration: const InputDecoration(
                  labelText: 'Mailbox ID (hex)',
                  hintText: '32-byte random mailbox identifier',
                ),
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (labelCtrl.text.isEmpty || keyCtrl.text.isEmpty) {
                return;
              }
              Navigator.of(ctx).pop();
              await service.addContact(
                label: labelCtrl.text.trim(),
                publicKey: keyCtrl.text.trim(),
                onionAddress: onionCtrl.text.trim(),
                mailboxId: mailboxCtrl.text.trim(),
              );
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
}

/// A single contact row.
class _ContactTile extends StatelessWidget {
  final Contact contact;
  final VoidCallback onTap;
  final VoidCallback onVerify;
  final VoidCallback onRemove;

  const _ContactTile({
    required this.contact,
    required this.onTap,
    required this.onVerify,
    required this.onRemove,
  });

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
      subtitle: Text(
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
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!contact.isVerified)
            IconButton(
              icon: Icon(Icons.verified_outlined,
                  color: AppTheme.warning, size: 20),
              tooltip: 'Verify fingerprint',
              onPressed: onVerify,
            ),
          if (contact.hasSession)
            StatusDot(color: AppTheme.success)
          else
            StatusDot(color: AppTheme.textSecondary),
        ],
      ),
      onTap: onTap,
      onLongPress: onRemove,
    );
  }
}

