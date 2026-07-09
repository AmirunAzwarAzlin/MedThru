import 'package:flutter/material.dart';
import '../api.dart';
import '../widgets.dart';
import 'patient_screen.dart';

/// Enter a card token (stands in for an NFC tap until the reader arrives).
class LookupScreen extends StatefulWidget {
  const LookupScreen({super.key});

  @override
  State<LookupScreen> createState() => _LookupScreenState();
}

class _LookupScreenState extends State<LookupScreen> {
  final _controller = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _lookup() async {
    final token = _controller.text.trim();
    if (token.isEmpty) {
      setState(() => _error = 'Enter a card token first.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final patient = await MedThruApi.instance.lookupByToken(token);
      if (!mounted) return;
      if (patient == null) {
        setState(() => _error = 'No patient registered for this card.');
      } else {
        Navigator.push(
          context,
          MaterialPageRoute(
            // Carry the token forward so readings can prove card possession.
            builder: (_) => PatientScreen(patient: patient, cardToken: token),
          ),
        );
      }
    } catch (e) {
      setState(() => _error = _friendly(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Read a card')),
      body: BoundedBody(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.nfc, size: 72, color: scheme.primary),
              const SizedBox(height: 24),
              TextField(
                controller: _controller,
                autofocus: true,
                textInputAction: TextInputAction.go,
                decoration: const InputDecoration(
                  labelText: 'Card token (UID)',
                  hintText: 'e.g. 04A1B2C3D4',
                  prefixIcon: Icon(Icons.credit_card),
                ),
                onSubmitted: (_) => _lookup(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(Icons.error_outline, size: 18, color: scheme.error),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(_error!,
                          style: TextStyle(color: scheme.error)),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _loading ? null : _lookup,
                child: _loading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Look up patient'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _friendly(Object e) {
  final msg = e.toString().replaceFirst('Exception: ', '');
  if (msg.contains('Connection') || msg.contains('SocketException')) {
    return 'Can\'t reach the server. Is it running? (npm start)';
  }
  if (msg.contains('Too many')) {
    return 'Too many lookups. Wait a minute and try again.';
  }
  return msg;
}
