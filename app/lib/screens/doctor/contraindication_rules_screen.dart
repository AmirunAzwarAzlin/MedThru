import 'package:flutter/material.dart';
import '../../api.dart';
import '../../theme.dart';
import '../../widgets.dart';

/// Administrator-only screen for managing the hard-stop rule table behind
/// the triage contraindication engine (see contraindication.js on the
/// server). Reachable from Settings when `MedThruApi.instance.isAdmin`.
class ContraindicationRulesScreen extends StatefulWidget {
  const ContraindicationRulesScreen({super.key});

  @override
  State<ContraindicationRulesScreen> createState() => _ContraindicationRulesScreenState();
}

class _ContraindicationRulesScreenState extends State<ContraindicationRulesScreen> {
  late Future<List<Map<String, dynamic>>> _rules;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _rules = MedThruApi.instance.getContraindicationRules();
  }

  Future<void> _openForm({Map<String, dynamic>? existing}) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => _RuleFormDialog(existing: existing),
    );
    if (saved == true && mounted) setState(_load);
  }

  Future<void> _delete(Map<String, dynamic> rule) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this rule?'),
        content: Text('This removes the "${rule['reason']}" rule. This can\'t be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep it')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: MedThruTheme.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await MedThruApi.instance.deleteContraindicationRule(rule['id'] as int);
      if (mounted) setState(_load);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Contraindication rules'),
        actions: [
          IconButton(
            onPressed: () => _openForm(),
            icon: const Icon(Icons.add),
            tooltip: 'Add rule',
          ),
        ],
      ),
      body: BoundedBody(
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _rules,
          builder: (context, snap) {
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final rules = snap.data!;
            if (rules.isEmpty) {
              return const Center(child: Text('No rules yet.'));
            }
            return ListView.separated(
              padding: const EdgeInsets.all(20),
              itemCount: rules.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final rule = rules[i];
                return Card(
                  child: ListTile(
                    title: Text(rule['reason'] as String),
                    subtitle: Text(
                      '${rule['rule_type']} · triggers: ${rule['trigger_terms']} · '
                      'treatment: ${rule['treatment_terms']} · severity: ${rule['severity']}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: () => _openForm(existing: rule),
                          icon: const Icon(Icons.edit_outlined),
                        ),
                        IconButton(
                          onPressed: () => _delete(rule),
                          icon: Icon(Icons.delete_outline, color: scheme.error),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _RuleFormDialog extends StatefulWidget {
  const _RuleFormDialog({this.existing});
  final Map<String, dynamic>? existing;

  @override
  State<_RuleFormDialog> createState() => _RuleFormDialogState();
}

class _RuleFormDialogState extends State<_RuleFormDialog> {
  late String _ruleType = widget.existing?['rule_type'] as String? ?? 'allergy';
  late final _triggerTerms =
      TextEditingController(text: widget.existing?['trigger_terms'] as String? ?? '');
  late final _treatmentTerms =
      TextEditingController(text: widget.existing?['treatment_terms'] as String? ?? '');
  late String _severity = widget.existing?['severity'] as String? ?? 'high';
  late final _reason = TextEditingController(text: widget.existing?['reason'] as String? ?? '');
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void dispose() {
    _triggerTerms.dispose();
    _treatmentTerms.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_triggerTerms.text.trim().isEmpty ||
        _treatmentTerms.text.trim().isEmpty ||
        _reason.text.trim().isEmpty) {
      setState(() => _error = 'All fields except severity are required.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_isEdit) {
        await MedThruApi.instance.updateContraindicationRule(
          widget.existing!['id'] as int,
          ruleType: _ruleType,
          triggerTerms: _triggerTerms.text.trim(),
          treatmentTerms: _treatmentTerms.text.trim(),
          severity: _severity,
          reason: _reason.text.trim(),
        );
      } else {
        await MedThruApi.instance.createContraindicationRule(
          ruleType: _ruleType,
          triggerTerms: _triggerTerms.text.trim(),
          treatmentTerms: _treatmentTerms.text.trim(),
          severity: _severity,
          reason: _reason.text.trim(),
        );
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(_isEdit ? 'Edit rule' : 'Add rule'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'allergy', label: Text('Allergy')),
                ButtonSegment(value: 'medication', label: Text('Medication')),
              ],
              selected: {_ruleType},
              onSelectionChanged: (s) => setState(() => _ruleType = s.first),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _triggerTerms,
              decoration: InputDecoration(
                labelText: _ruleType == 'allergy' ? 'Allergen keywords' : 'Existing medication keywords',
                hintText: 'comma-separated, e.g. penicillin,amoxicillin',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _treatmentTerms,
              decoration: const InputDecoration(
                labelText: 'Proposed treatment keywords',
                hintText: 'comma-separated, e.g. amoxicillin,ampicillin',
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'high', label: Text('High')),
                ButtonSegment(value: 'moderate', label: Text('Moderate')),
              ],
              selected: {_severity},
              onSelectionChanged: (s) => setState(() => _severity = s.first),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _reason,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Reason shown to the doctor',
                alignLabelWithHint: true,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: scheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
    );
  }
}
