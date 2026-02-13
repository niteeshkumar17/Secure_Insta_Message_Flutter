import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../widgets/common_widgets.dart';

/// About / Warnings Screen (Screen 5)
///
/// Displays:
/// - Experimental notice
/// - Threat model summary
/// - Mobile limitations explanation
/// - Links to repo documentation
///
/// This screen exists to be HONEST with users about what the
/// app can and cannot guarantee.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            _buildHeader(context),
            const SizedBox(height: 16),

            // Experimental Warning
            _buildExperimentalWarning(context),
            const SizedBox(height: 12),

            // Threat Model Summary
            _buildThreatModelSummary(context),
            const SizedBox(height: 12),

            // Mobile Limitations
            _buildMobileLimitations(context),
            const SizedBox(height: 12),

            // Unsupported Features
            _buildUnsupportedFeatures(context),
            const SizedBox(height: 12),

            // Why Slow
            _buildWhySlow(context),
            const SizedBox(height: 12),

            // Links
            _buildLinks(context),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Column(
      children: [
        Icon(Icons.shield, size: 48, color: AppTheme.primary),
        const SizedBox(height: 12),
        Text(
          'Secure Insta Message',
          style: Theme.of(context).textTheme.headlineLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text(
          'v1.0.0-experimental',
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontFamily: 'monospace',
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: AppTheme.warning.withOpacity(0.1),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppTheme.warning.withOpacity(0.3)),
          ),
          child: Text(
            'Experimental. Privacy-preserving. Not optimized for convenience.',
            style: TextStyle(color: AppTheme.warning, fontSize: 11),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'This is a UI client for the Secure Insta Message protocol.\n'
          'The reference implementation remains the CLI.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildExperimentalWarning(BuildContext context) {
    return SecurityCard(
      title: 'Experimental Software',
      icon: Icons.science_outlined,
      child: Text(
        'This software has NOT been professionally audited. '
        'The cryptographic design is based on well-studied protocols '
        '(Signal Protocol, Tor), but the implementation may contain bugs.\n\n'
        'Do not rely on this for life-or-death situations until '
        'a professional audit has been completed.',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }

  Widget _buildThreatModelSummary(BuildContext context) {
    return SecurityCard(
      title: 'Threat Model Summary',
      icon: Icons.policy_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _threatItem('Message content', 'AES-256-GCM via Double Ratchet'),
          _threatItem('Sender identity', 'Sealed sender (ephemeral ECDH)'),
          _threatItem('Recipient identity', 'Tor .onion addressing'),
          _threatItem('Communication timing', 'Constant-rate cover traffic'),
          _threatItem('Message size', 'Fixed 32KB padding (CSPRNG fill)'),
          _threatItem('Contact list', 'Argon2id-encrypted local keystore'),
          _threatItem('Session keys', 'Double Ratchet (forward + future secrecy)'),
          _threatItem('Network traffic', 'Tor-only with kill-switch'),
          _threatItem('Delivery metadata', 'Only SHA-256(ciphertext)'),
          const SizedBox(height: 8),
          const Divider(),
          const SizedBox(height: 8),
          Text(
            'Security Invariants (must always hold):',
            style: TextStyle(
                fontWeight: FontWeight.w600,
                color: AppTheme.primary,
                fontSize: 13),
          ),
          const SizedBox(height: 8),
          _invariant('No plaintext leaves the device'),
          _invariant('No real-world identifier enters the protocol'),
          _invariant('No packet reveals its content type'),
          _invariant('No packet contains a timestamp'),
          _invariant('No server can identify the sender'),
          _invariant('No single relay knows both endpoints'),
          _invariant('No traffic pattern reveals activity'),
          _invariant('No key compromise reveals past messages'),
          _invariant('No network traffic bypasses Tor'),
        ],
      ),
    );
  }

  Widget _buildMobileLimitations(BuildContext context) {
    return SecurityCard(
      title: 'Mobile Limitations',
      icon: Icons.phone_android,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          WarningBanner(
            text: 'Desktop CLI remains the strongest client.',
            color: AppTheme.warning,
          ),
          const SizedBox(height: 12),
          _limitation(
            'Background Execution',
            'OS may pause cover traffic when app is backgrounded, '
            'temporarily reducing anonymity.',
          ),
          _limitation(
            'Power Management',
            'Battery optimization may affect timing precision of '
            'cover traffic and mailbox polling.',
          ),
          _limitation(
            'No Push Notifications',
            'Push notifications (FCM/APNS) are intentionally absent. '
            'They would route through Google/Apple servers, leaking metadata.',
          ),
          _limitation(
            'Idle Anonymity',
            'When the device is idle, cover traffic may stop, '
            'making traffic analysis easier for an adversary monitoring '
            'the Tor network.',
          ),
        ],
      ),
    );
  }

  Widget _buildUnsupportedFeatures(BuildContext context) {
    return SecurityCard(
      title: 'Intentionally Unsupported',
      icon: Icons.block,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'These features are excluded by design to protect '
            'the threat model:',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          _forbiddenItem('Push notifications (FCM / APNS)'),
          _forbiddenItem('Typing indicators'),
          _forbiddenItem('Read receipts'),
          _forbiddenItem('Online / last-seen status'),
          _forbiddenItem('Voice calls'),
          _forbiddenItem('Video calls'),
          _forbiddenItem('Media streaming'),
          _forbiddenItem('Contact syncing'),
          _forbiddenItem('Phone number or email identity'),
          _forbiddenItem('Analytics, telemetry, crash reporting'),
          _forbiddenItem('WebRTC / STUN / TURN'),
          _forbiddenItem('Cloud account login'),
        ],
      ),
    );
  }

  Widget _buildWhySlow(BuildContext context) {
    return SecurityCard(
      title: 'Why Messages Are Slow',
      icon: Icons.hourglass_bottom,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Expected latency: 3–10 seconds per message.\n'
            'This is by design.',
            style: TextStyle(
                color: AppTheme.warning, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 12),
          _latencyItem('Cover traffic queue', '~2s avg',
              'Prevents timing analysis'),
          _latencyItem('Proof-of-Work', '~0.5s',
              'Prevents relay spam'),
          _latencyItem('Onion routing (3+ hops)', '~1–3s',
              'No single relay knows both endpoints'),
          _latencyItem('Tor circuit latency', '~0.2–0.5s/hop',
              'IP address hiding'),
          const SizedBox(height: 8),
          Text(
            'Reducing any of these weakens the security guarantees. '
            'See WHY_THIS_IS_SLOW.md in the repository.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildLinks(BuildContext context) {
    return SecurityCard(
      title: 'Documentation',
      icon: Icons.menu_book,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _linkItem('Repository',
              'github.com/niteeshkumar17/Secure_Insta_Message'),
          _linkItem('Protocol Specification', 'PROTOCOL.md'),
          _linkItem('Threat Model', 'THREAT_MODEL.md'),
          _linkItem('Security Policy', 'SECURITY.md'),
          _linkItem('Known Limitations', 'KNOWN_LIMITATIONS.md'),
          _linkItem('Why This Is Slow', 'WHY_THIS_IS_SLOW.md'),
          _linkItem('Audit Map', 'AUDIT_MAP.md'),
        ],
      ),
    );
  }

  // --- Helper widgets ---

  Widget _threatItem(String asset, String protection) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.check_circle_outline,
              size: 14, color: AppTheme.success),
          const SizedBox(width: 8),
          Expanded(
            child: RichText(
              text: TextSpan(
                children: [
                  TextSpan(
                    text: '$asset: ',
                    style: const TextStyle(
                        fontWeight: FontWeight.w500, fontSize: 13),
                  ),
                  TextSpan(
                    text: protection,
                    style: TextStyle(
                        color: AppTheme.textSecondary, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _invariant(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.shield_outlined,
              size: 14, color: AppTheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _limitation(String title, String description) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
                fontWeight: FontWeight.w600,
                color: AppTheme.warning,
                fontSize: 13),
          ),
          const SizedBox(height: 2),
          Text(description, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  Widget _forbiddenItem(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(Icons.close, size: 14, color: AppTheme.error),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  Widget _latencyItem(String component, String latency, String reason) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 60,
            child: Text(
              latency,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: AppTheme.primary,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(component,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w500)),
                Text(reason,
                    style: TextStyle(
                        fontSize: 11, color: AppTheme.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _linkItem(String label, String url) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(Icons.link, size: 14, color: AppTheme.primary),
          const SizedBox(width: 8),
          Text('$label — ', style: const TextStyle(fontSize: 12)),
          Expanded(
            child: Text(
              url,
              style: TextStyle(
                fontSize: 11,
                color: AppTheme.primary,
                fontFamily: 'monospace',
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

