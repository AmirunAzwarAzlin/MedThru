import 'dart:async';
import 'package:flutter/material.dart';
import '../../api.dart';
import '../../widgets.dart';

/// One patient's message thread, shared by both sides. In patient mode the
/// [cardToken] path is used and the patient's own messages sit on the right; in
/// doctor mode [patientId] is used and the doctor's messages sit on the right.
/// Polls every few seconds so a reply from the other side appears on its own.
class ConversationScreen extends StatefulWidget {
  const ConversationScreen({
    super.key,
    this.cardToken,
    this.patientId,
    this.title = 'Messages',
  }) : assert(cardToken != null || patientId != null,
            'Need a card token (patient) or a patient id (doctor)');

  /// Patient mode: the card token to send/receive under.
  final String? cardToken;

  /// Doctor mode: the patient whose thread this is.
  final int? patientId;
  final String title;

  bool get asDoctor => cardToken == null;

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  List<Map<String, dynamic>> _messages = const [];
  bool _loading = true;
  bool _sending = false;
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _fetch();
    // A quiet poll so the other side's replies arrive without a manual refresh.
    _poll = Timer.periodic(const Duration(seconds: 6), (_) => _fetch(silent: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _fetch({bool silent = false}) async {
    try {
      final msgs = widget.asDoctor
          ? await MedThruApi.instance.getMessagesForPatient(widget.patientId!)
          : await MedThruApi.instance.getMessages(widget.cardToken!);
      if (!mounted) return;
      final grew = msgs.length != _messages.length;
      setState(() {
        _messages = msgs;
        _loading = false;
        _error = null;
      });
      if (grew) _scrollToBottom();
    } catch (e) {
      if (!mounted || silent) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      if (widget.asDoctor) {
        await MedThruApi.instance.sendMessageAsDoctor(widget.patientId!, text);
      } else {
        await MedThruApi.instance.sendMessageAsPatient(widget.cardToken!, text);
      }
      _input.clear();
      await _fetch(silent: true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: BoundedBody(
        maxWidth: 720,
        child: Column(
          children: [
            Expanded(child: _body(scheme)),
            _Composer(
              controller: _input,
              sending: _sending,
              onSend: _send,
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(ColorScheme scheme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null && _messages.isEmpty) {
      return CenteredMessage(
        icon: Icons.error_outline,
        title: 'Could not load messages',
        subtitle: _error,
        action: OutlinedButton.icon(
          onPressed: () => setState(() {
            _loading = true;
            _fetch();
          }),
          icon: const Icon(Icons.refresh),
          label: const Text('Try again'),
        ),
      );
    }
    if (_messages.isEmpty) {
      return CenteredMessage(
        icon: Icons.forum_outlined,
        title: 'No messages yet',
        subtitle: widget.asDoctor
            ? 'Send the first message to this patient.'
            : 'Send a message to your care team.',
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
      itemCount: _messages.length,
      itemBuilder: (context, i) {
        final m = _messages[i];
        final mine = widget.asDoctor ? m['sender'] == 'doctor' : m['sender'] == 'patient';
        return _Bubble(message: m, mine: mine, asDoctor: widget.asDoctor);
      },
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.mine, required this.asDoctor});
  final Map<String, dynamic> message;
  final bool mine;
  final bool asDoctor;

  String get _who {
    // Label the *other* side. From the doctor's seat a patient message reads
    // "Patient"; from the patient's seat a doctor message shows the clinician.
    if (message['sender'] == 'doctor') {
      return message['doctor_name'] as String? ?? 'Clinician';
    }
    return 'Patient';
  }

  String _time() {
    final raw = message['created_at'] as String? ?? '';
    // Stored "YYYY-MM-DD HH:MM:SS" — show just HH:MM.
    return raw.length >= 16 ? raw.substring(11, 16) : raw;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = mine ? scheme.primary : scheme.surfaceContainerHigh;
    final fg = mine ? scheme.onPrimary : scheme.onSurface;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (!mine)
            Padding(
              padding: const EdgeInsets.only(left: 6, bottom: 2),
              child: Text(_who,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant)),
            ),
          Row(
            mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(mine ? 16 : 4),
                      bottomRight: Radius.circular(mine ? 4 : 16),
                    ),
                  ),
                  child: Text(message['body'] as String? ?? '',
                      style: TextStyle(color: fg, fontSize: 14.5, height: 1.3)),
                ),
              ),
            ],
          ),
          Padding(
            padding: EdgeInsets.only(top: 2, left: mine ? 0 : 6, right: mine ? 6 : 0),
            child: Text(_time(),
                style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({required this.controller, required this.sending, required this.onSend});
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  hintText: 'Write a message…',
                  contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                ),
                onSubmitted: (_) => onSend(),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 48,
              width: 48,
              child: FilledButton(
                onPressed: sending ? null : onSend,
                style: FilledButton.styleFrom(
                  padding: EdgeInsets.zero,
                  shape: const CircleBorder(),
                  backgroundColor: scheme.primary,
                ),
                child: sending
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.send, size: 20, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
