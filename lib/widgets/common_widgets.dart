import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// A warning banner displayed prominently throughout the app.
///
/// Used for security-critical notices that the user must be
/// aware of at all times.
class WarningBanner extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color? color;

  const WarningBanner({
    super.key,
    required this.text,
    this.icon = Icons.warning_amber_rounded,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final bannerColor = color ?? AppTheme.warning;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: bannerColor.withOpacity(0.1),
        border: Border(
          bottom: BorderSide(color: bannerColor.withOpacity(0.3)),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: bannerColor, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: bannerColor, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// Status indicator dot.
class StatusDot extends StatelessWidget {
  final Color color;
  final double size;

  const StatusDot({
    super.key,
    required this.color,
    this.size = 8,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.4),
            blurRadius: 4,
            spreadRadius: 1,
          ),
        ],
      ),
    );
  }
}

/// A monospace text widget for displaying keys and fingerprints.
class MonospaceText extends StatelessWidget {
  final String text;
  final double fontSize;
  final Color? color;
  final bool selectable;

  const MonospaceText({
    super.key,
    required this.text,
    this.fontSize = 13,
    this.color,
    this.selectable = true,
  });

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontFamily: 'monospace',
      fontSize: fontSize,
      color: color ?? AppTheme.primary,
      letterSpacing: 1.2,
    );

    if (selectable) {
      return SelectableText(text, style: style);
    }
    return Text(text, style: style);
  }
}

/// A card for displaying security-critical information.
class SecurityCard extends StatelessWidget {
  final String title;
  final Widget child;
  final IconData? icon;

  const SecurityCard({
    super.key,
    required this.title,
    required this.child,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: AppTheme.textSecondary),
                  const SizedBox(width: 8),
                ],
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

/// A dialog for unsupported features.
///
/// When users try to access features that violate the threat model,
/// this dialog explains WHY the feature is absent.
class UnsupportedFeatureDialog extends StatelessWidget {
  final String featureName;

  const UnsupportedFeatureDialog({
    super.key,
    required this.featureName,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.surface,
      title: Row(
        children: [
          Icon(Icons.shield_outlined, color: AppTheme.warning),
          const SizedBox(width: 8),
          const Text('Feature Unavailable'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '"$featureName" is intentionally unsupported due to '
            "the project's threat model.",
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Text(
            'This is not a bug. Privacy-violating features are '
            'excluded by design to protect you.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Understood'),
        ),
      ],
    );
  }

  static void show(BuildContext context, String featureName) {
    showDialog(
      context: context,
      builder: (_) => UnsupportedFeatureDialog(featureName: featureName),
    );
  }
}

