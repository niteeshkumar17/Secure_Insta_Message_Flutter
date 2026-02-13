import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/identity_service.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';

/// Identity Screen (Screen 1)
///
/// Displays:
/// - Public key fingerprint
/// - Export identity (QR / file)
/// - Import identity
/// - Warning about key loss
class IdentityScreen extends StatefulWidget {
  const IdentityScreen({super.key});

  @override
  State<IdentityScreen> createState() => _IdentityScreenState();
}

class _IdentityScreenState extends State<IdentityScreen> {
  final _passphraseController = TextEditingController();
  bool _showPassphrase = false;
  bool _showQr = false;

  @override
  void dispose() {
    // Securely clear passphrase from memory
    _passphraseController.clear();
    _passphraseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<IdentityService>(
      builder: (context, identityService, _) {
        final identity = identityService.identity;

        return Scaffold(
          appBar: AppBar(
            title: const Text('Identity'),
            actions: [
              if (identity.isLoaded)
                IconButton(
                  icon: const Icon(Icons.qr_code),
                  tooltip: 'Show QR Code',
                  onPressed: () => setState(() => _showQr = !_showQr),
                ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Key loss warning — always visible
                const WarningBanner(
                  text: 'Losing this key permanently loses access. '
                      'There is no recovery mechanism.',
                  icon: Icons.warning_amber_rounded,
                ),
                const SizedBox(height: 16),

                if (identity.isLoaded) ...[
                  // Identity loaded — show fingerprint
                  _buildIdentityDisplay(context, identityService),
                ] else ...[
                  // No identity — show generate/import
                  _buildIdentitySetup(context, identityService),
                ],

                if (identityService.error != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.error.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      identityService.error!,
                      style: TextStyle(color: AppTheme.error, fontSize: 13),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildIdentityDisplay(
      BuildContext context, IdentityService service) {
    final identity = service.identity;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Fingerprint card
        SecurityCard(
          title: 'Public Key Fingerprint',
          icon: Icons.fingerprint,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MonospaceText(text: identity.formattedFingerprint),
              const SizedBox(height: 8),
              Text(
                'Share this with your contacts for verification.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy Fingerprint'),
                onPressed: () {
                  Clipboard.setData(
                      ClipboardData(text: identity.fingerprint));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Fingerprint copied to clipboard')),
                  );
                },
              ),
            ],
          ),
        ),

        // Onion address
        if (identity.onionAddress != null) ...[
          const SizedBox(height: 12),
          SecurityCard(
            title: 'Onion Address',
            icon: Icons.security,
            child: MonospaceText(
              text: identity.onionAddress!,
              fontSize: 11,
            ),
          ),
        ],

        // QR code for sharing
        if (_showQr) ...[
          const SizedBox(height: 12),
          SecurityCard(
            title: 'Share Identity (QR)',
            icon: Icons.qr_code,
            child: Center(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: QrImageView(
                  data: identity.publicKey,
                  version: QrVersions.auto,
                  size: 200,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
          ),
        ],

        // Export button
        const SizedBox(height: 16),
        OutlinedButton.icon(
          icon: const Icon(Icons.upload_outlined, size: 18),
          label: const Text('Export Identity'),
          onPressed: () async {
            final data = await service.exportIdentity();
            if (data != null && mounted) {
              Clipboard.setData(ClipboardData(text: data));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Identity export data copied')),
              );
            }
          },
        ),
      ],
    );
  }

  Widget _buildIdentitySetup(
      BuildContext context, IdentityService service) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SecurityCard(
          title: 'Set Up Identity',
          icon: Icons.person_add_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Generate a new Ed25519 identity or import an existing one.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),

              // Passphrase field
              TextField(
                controller: _passphraseController,
                obscureText: !_showPassphrase,
                decoration: InputDecoration(
                  labelText: 'Passphrase',
                  hintText: 'Strong passphrase to encrypt your keystore',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _showPassphrase
                          ? Icons.visibility_off
                          : Icons.visibility,
                    ),
                    onPressed: () =>
                        setState(() => _showPassphrase = !_showPassphrase),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Your keys are encrypted with Argon2id (256 MB, 3 passes).',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),

              // Generate button
              ElevatedButton.icon(
                icon: service.isLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_circle_outline, size: 18),
                label: const Text('Generate New Identity'),
                onPressed: service.isLoading
                    ? null
                    : () => _generateIdentity(service),
              ),

              const SizedBox(height: 8),

              // Load existing
              OutlinedButton.icon(
                icon: const Icon(Icons.folder_open, size: 18),
                label: const Text('Load Existing Identity'),
                onPressed: service.isLoading
                    ? null
                    : () => _loadIdentity(service),
              ),

              const SizedBox(height: 8),

              // Import
              OutlinedButton.icon(
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('Import Identity'),
                onPressed: () => _showImportDialog(context, service),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _generateIdentity(IdentityService service) async {
    final passphrase = _passphraseController.text;
    if (passphrase.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Passphrase is required'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    final success =
        await service.generateIdentity(passphrase: passphrase);
    if (success && mounted) {
      _passphraseController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Identity generated. Save your seed!'),
          backgroundColor: AppTheme.success,
        ),
      );
    }
  }

  Future<void> _loadIdentity(IdentityService service) async {
    final passphrase = _passphraseController.text;
    if (passphrase.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Passphrase is required'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    final success =
        await service.loadIdentity(passphrase: passphrase);
    if (success && mounted) {
      _passphraseController.clear();
    }
  }

  void _showImportDialog(
      BuildContext context, IdentityService service) {
    final importController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Import Identity'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Paste the exported identity data:'),
            const SizedBox(height: 12),
            TextField(
              controller: importController,
              maxLines: 5,
              decoration: const InputDecoration(
                hintText: 'Paste identity data...',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final data = importController.text.trim();
              if (data.isNotEmpty) {
                Navigator.of(ctx).pop();
                await service.importIdentity(
                  importData: data,
                  passphrase: _passphraseController.text,
                );
              }
            },
            child: const Text('Import'),
          ),
        ],
      ),
    );
  }
}

