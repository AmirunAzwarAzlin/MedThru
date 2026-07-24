import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'api.dart';
import 'notifications.dart';
import 'theme.dart';
import 'screens/home_screen.dart';
import 'screens/patient/patient_screen.dart';

/// Dev convenience: launching with `--doctor` (or MEDIC_ROLE=doctor) signs in
/// automatically so you don't retype credentials on every restart. Gated on
/// kDebugMode so it can never activate in a release build.
bool _wantsAutoDoctor(List<String> args) {
  if (!kDebugMode) return false;
  if (args.contains('--doctor')) return true;
  if (!kIsWeb && Platform.environment['MEDIC_ROLE'] == 'doctor') return true;
  return false;
}

/// The NFC reader bridge (reader.js) launches the app with `--token=<card
/// token>` when it sees a tap and the app isn't already running, so the
/// record opens immediately instead of the tap being silently missed.
String? _tapToken(List<String> args) {
  for (final arg in args) {
    if (arg.startsWith('--token=')) return arg.substring('--token='.length);
  }
  return null;
}

void main(List<String> args) {
  runApp(
    MedThruApp(
      autoLoginAsDoctor: _wantsAutoDoctor(args),
      tapToken: _tapToken(args),
    ),
  );
}

class MedThruApp extends StatefulWidget {
  const MedThruApp({
    super.key,
    this.autoLoginAsDoctor = false,
    this.tapToken,
    this.enableTapListening = true,
    this.enableNotifications = true,
  });

  final bool autoLoginAsDoctor;
  final String? tapToken;

  /// Off in widget tests: the app-wide tap listener opens a real HTTP
  /// connection from `initState`, which has nothing to talk to in a test
  /// environment and leaves a reconnect timer pending after the test ends.
  final bool enableTapListening;

  /// Off in widget tests: initializing the notifications plugin touches
  /// platform channels that aren't mocked in a test environment.
  final bool enableNotifications;

  @override
  State<MedThruApp> createState() => _MedThruAppState();
}

class _MedThruAppState extends State<MedThruApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  StreamSubscription<String>? _tapSub;

  @override
  void initState() {
    super.initState();
    if (widget.autoLoginAsDoctor) _autoLogin();
    if (widget.enableTapListening) _subscribeToTaps();
    if (widget.enableNotifications) NotificationService.instance.init();
  }

  @override
  void dispose() {
    _tapSub?.cancel();
    super.dispose();
  }

  /// Uses a real login so the session carries a valid token — a faked one
  /// would be rejected by the server the moment you tried to edit anything.
  Future<void> _autoLogin() async {
    final env = kIsWeb ? const <String, String>{} : Platform.environment;
    final email = env['MEDIC_DEV_EMAIL'] ?? 'admin';
    final password = env['MEDIC_DEV_PASSWORD'] ?? 'admin123';
    try {
      await MedThruApi.instance.login(email, password);
    } catch (_) {
      // Server down or credentials changed: just start signed out.
    }
  }

  /// Listens for a card tap from the app root rather than from any one
  /// screen, so a tap opens the patient's record no matter what you're
  /// doing in the app at the time — there's no dedicated "read a card"
  /// screen to be on top of anymore. The SSE connection can drop (server
  /// restart, brief hiccup); reconnect after a short delay rather than
  /// going quietly deaf.
  void _subscribeToTaps() {
    if (!mounted) return;
    MedThruApi.instance.setTapStreamListening(true);
    _tapSub = MedThruApi.instance.watchTaps().listen(
      _onTap,
      onError: (_) => _scheduleReconnect(),
      onDone: _scheduleReconnect,
    );
  }

  void _scheduleReconnect() {
    if (!mounted) return;
    MedThruApi.instance.setTapStreamListening(false);
    Future.delayed(const Duration(seconds: 3), _subscribeToTaps);
  }

  Future<void> _onTap(String token) async {
    if (MedThruApi.instance.tapLookupInProgress) return; // already handling a tap
    MedThruApi.instance.setTapLookupInProgress(true);
    try {
      final context = _navigatorKey.currentContext;
      if (context == null) return;
      final resolved = await resolveTappedPatient(context, token);
      if (!mounted || resolved == null) return;
      if (resolved.patient == null) {
        _messengerKey.currentState?.showSnackBar(
          const SnackBar(content: Text('No patient registered for this card.')),
        );
      } else {
        _navigatorKey.currentState?.push(
          MaterialPageRoute(
            builder: (_) => PatientScreen(
              patient: resolved.patient!,
              cardToken: token,
              unlockPassword: resolved.password,
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      _messengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) MedThruApi.instance.setTapLookupInProgress(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _messengerKey,
      title: 'Med-IC',
      debugShowCheckedModeBanner: false,
      theme: MedThruTheme.light(),
      darkTheme: MedThruTheme.dark(),
      // Light-first: the "warm daylight" direction is the design. Dark stays as
      // a coherent fallback for anyone who forces it at the OS level.
      themeMode: ThemeMode.light,
      // HomeScreen subscribes to auth changes itself. (Don't wrap it in an
      // AnimatedBuilder returning a `const` child: const widgets are
      // canonicalized, so Flutter skips the rebuild and the screen goes stale.)
      home: widget.tapToken == null
          ? const HomeScreen()
          : _TapLaunchScreen(token: widget.tapToken!),
    );
  }
}

/// Shown for the instant it takes to resolve the card that launched the app.
/// Falls back to the normal home screen if the token turns out to be dead
/// (card revoked between the tap and the app finishing its cold start).
class _TapLaunchScreen extends StatefulWidget {
  const _TapLaunchScreen({required this.token});
  final String token;

  @override
  State<_TapLaunchScreen> createState() => _TapLaunchScreenState();
}

class _TapLaunchScreenState extends State<_TapLaunchScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _openPatient());
  }

  Future<void> _openPatient() async {
    TappedPatient? resolved;
    try {
      resolved = await resolveTappedPatient(context, widget.token);
    } catch (_) {
      resolved = null;
    }
    if (!mounted) return;
    final patient = resolved?.patient;
    Navigator.of(context).pushReplacement(
      patient == null
          ? MaterialPageRoute(builder: (_) => const HomeScreen())
          : MaterialPageRoute(
              builder: (_) => PatientScreen(
                patient: patient,
                cardToken: widget.token,
                unlockPassword: resolved!.password,
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

/// The result of resolving a tapped card token to a patient, threading a
/// password through if the card turned out to need one. `patient` is null
/// when the token isn't registered to anyone.
typedef TappedPatient = ({Map<String, dynamic>? patient, String? password});

/// Looks up a tapped card token, prompting for the card's password if (and
/// only if) the server says one is needed — see [PasswordRequiredException].
/// Returns null if the user cancels that prompt instead of finishing it. The
/// password actually used comes back alongside the patient record so the
/// caller (see [PatientScreen.unlockPassword]) can keep working — e.g.
/// pull-to-refresh — without prompting again for the rest of that visit.
Future<TappedPatient?> resolveTappedPatient(BuildContext context, String token) async {
  try {
    final patient = await MedThruApi.instance.lookupByToken(token);
    return (patient: patient, password: null);
  } on PasswordRequiredException {
    if (!context.mounted) return null;
    return showDialog<TappedPatient>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CardPasswordDialog(token: token),
    );
  }
}

/// Shown when a tapped card belongs to a patient who's set up a card
/// password. Verifies inline so the same dialog can show "incorrect
/// password" and let the user retry, rather than closing and reopening.
class _CardPasswordDialog extends StatefulWidget {
  const _CardPasswordDialog({required this.token});
  final String token;

  @override
  State<_CardPasswordDialog> createState() => _CardPasswordDialogState();
}

class _CardPasswordDialogState extends State<_CardPasswordDialog> {
  final _password = TextEditingController();
  bool _checking = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final patient = await MedThruApi.instance.lookupByToken(
        widget.token,
        password: _password.text,
      );
      if (!mounted) return;
      Navigator.pop<TappedPatient>(
        context,
        (patient: patient, password: _password.text),
      );
    } on PasswordRequiredException {
      if (!mounted) return;
      setState(() {
        _error = 'Incorrect password.';
        _checking = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _checking = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: const Icon(Icons.lock_outline),
      title: const Text('Card password required'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _password,
            obscureText: true,
            autofocus: true,
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(labelText: 'Password'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: scheme.error)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _checking ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _checking ? null : _submit,
          child: _checking
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Enter'),
        ),
      ],
    );
  }
}
