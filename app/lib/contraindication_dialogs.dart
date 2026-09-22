import 'package:flutter/material.dart';

/// Blocking dialog for a deterministic hard-stop match: lists every matched
/// rule's reason and requires the doctor to type a justification before the
/// proceed button enables. Returns the typed reason, or `null` if the
/// doctor cancelled instead.
Future<String?> showHardStopOverrideDialog(
  BuildContext context, {
  required List<Map<String, dynamic>> hardStops,
}) {
  final reasonController = TextEditingController();
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        icon: Icon(Icons.dangerous_outlined, color: Theme.of(context).colorScheme.error),
        title: const Text('Possible dangerous interaction'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final stop in hardStops) ...[
                Text(
                  '${(stop['triggerSource'] as String) == 'allergy' ? 'Allergy' : 'Current medication'}: '
                  '${stop['triggerLabel']}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(stop['reason'] as String),
                const SizedBox(height: 12),
              ],
              Text(
                "Type a reason to proceed anyway. This is recorded in the patient's audit log.",
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: reasonController,
                autofocus: true,
                maxLines: 2,
                onChanged: (_) => setDialogState(() {}),
                decoration: const InputDecoration(hintText: 'e.g. Desensitization already in place'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: reasonController.text.trim().isEmpty
                ? null
                : () => Navigator.pop(context, reasonController.text.trim()),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Proceed anyway'),
          ),
        ],
      ),
    ),
  );
}

/// Dismissible warning for a Gemini-only flag (no hard-stop rule matched).
/// Returns `true` if the doctor chose to proceed, `false` if they cancelled.
Future<bool> showAiWarningDialog(
  BuildContext context, {
  required Map<String, dynamic> aiFlag,
}) async {
  final proceed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.warning_amber_outlined),
      title: const Text('Possible interaction to review'),
      content: Text(
        aiFlag['reason'] as String? ??
            "This treatment may interact with the patient's allergies or medications.",
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Proceed anyway'),
        ),
      ],
    ),
  );
  return proceed ?? false;
}
