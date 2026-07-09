import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'api.dart';
import 'theme.dart';
import 'screens/home_screen.dart';

/// Dev convenience: launching with `--doctor` (or MEDIC_ROLE=doctor) signs in
/// automatically so you don't retype credentials on every restart. Gated on
/// kDebugMode so it can never activate in a release build.
bool _wantsAutoDoctor(List<String> args) {
  if (!kDebugMode) return false;
  if (args.contains('--doctor')) return true;
  if (!kIsWeb && Platform.environment['MEDIC_ROLE'] == 'doctor') return true;
  return false;
}

void main(List<String> args) {
  runApp(MedThruApp(autoLoginAsDoctor: _wantsAutoDoctor(args)));
}

class MedThruApp extends StatefulWidget {
  const MedThruApp({super.key, this.autoLoginAsDoctor = false});

  final bool autoLoginAsDoctor;

  @override
  State<MedThruApp> createState() => _MedThruAppState();
}

class _MedThruAppState extends State<MedThruApp> {
  @override
  void initState() {
    super.initState();
    if (widget.autoLoginAsDoctor) _autoLogin();
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

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Med-IC',
      debugShowCheckedModeBanner: false,
      theme: MedThruTheme.light(),
      darkTheme: MedThruTheme.dark(),
      themeMode: ThemeMode.system,
      // HomeScreen subscribes to auth changes itself. (Don't wrap it in an
      // AnimatedBuilder returning a `const` child: const widgets are
      // canonicalized, so Flutter skips the rebuild and the screen goes stale.)
      home: const HomeScreen(),
    );
  }
}
