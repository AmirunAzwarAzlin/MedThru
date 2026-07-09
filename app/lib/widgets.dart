import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shows a freshly issued card token. This is the only time the raw token is
/// ever visible — the server stores just a hash — so it must be written to the
/// card now. Blocking dialog, deliberately: dismissing it loses the token.
Future<void> showCardTokenDialog(
  BuildContext context, {
  required String token,
  required String patientName,
  bool isReissue = false,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        icon: Icon(Icons.nfc, color: scheme.primary, size: 32),
        title: Text(isReissue ? 'New card issued' : 'Card issued'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isReissue
                  ? 'The old card for $patientName no longer works. Write this '
                      'token to the replacement card now.'
                  : 'Write this token to $patientName\'s blank card now.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: SelectableText(
                token,
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 13, height: 1.4),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.warning_amber_outlined,
                    size: 16, color: scheme.error),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'This token is shown only once and cannot be recovered.',
                    style: TextStyle(fontSize: 12, color: scheme.error),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: token));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Token copied')),
              );
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            style: FilledButton.styleFrom(
                minimumSize: const Size(100, 42)),
            child: const Text('Done'),
          ),
        ],
      );
    },
  );
}

/// A labelled read-only field shown on the patient record.
class FieldCard extends StatelessWidget {
  const FieldCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: scheme.primary),
        title: Text(
          label,
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
        subtitle: Text(
          value,
          style: TextStyle(
            fontSize: 16,
            color: scheme.onSurface,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// Full-screen centered state used for empty / error / loading screens.
class CenteredMessage extends StatelessWidget {
  const CenteredMessage({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: 20),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Constrains form/content width so it looks right on wide desktop windows.
class BoundedBody extends StatelessWidget {
  const BoundedBody({super.key, required this.child, this.maxWidth = 460});
  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
