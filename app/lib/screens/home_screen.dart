import 'package:flutter/material.dart';
import '../api.dart';
import '../theme.dart';
import 'auth/doctor_login_screen.dart';
import 'doctor/doctor_profile_screen.dart';
import 'doctor/doctor_settings_screen.dart';
import 'auth/patient_login_screen.dart';
import 'auth/register_patient_screen.dart';
import 'doctor/patient_directory_screen.dart';
import 'doctor/appointment_queue_screen.dart';
import 'doctor/doctor_dashboard_screen.dart';

/// Landing page: introduces Med-IC before pushing anyone to sign in,
/// then offers the actions. Becomes doctor-aware once signed in.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _api = MedThruApi.instance;

  @override
  void initState() {
    super.initState();
    _api.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    _api.removeListener(_onAuthChanged);
    super.dispose();
  }

  void _onAuthChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final api = _api;
    final isDoctor = api.isLoggedIn;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            title: const _BrandMark(),
            actions: [
              if (isDoctor) ...[
                IconButton(
                  tooltip: 'Register patient',
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const RegisterPatientScreen()),
                  ),
                ),
                IconButton(
                  tooltip: 'Requests',
                  icon: const Icon(Icons.event_note_outlined),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AppointmentQueueScreen()),
                  ),
                ),
                IconButton(
                  tooltip: 'Patients',
                  icon: const Icon(Icons.people_outline),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const PatientDirectoryScreen()),
                  ),
                ),
                // Account actions tucked into a menu so the bar stays tidy on
                // phones while still exposing the primary nav as icons.
                PopupMenuButton<String>(
                  tooltip: 'Account',
                  icon: const Icon(Icons.account_circle_outlined),
                  onSelected: (v) {
                    if (v == 'profile') {
                      Navigator.push(context,
                          MaterialPageRoute(builder: (_) => const DoctorProfileScreen()));
                    } else if (v == 'settings') {
                      Navigator.push(context,
                          MaterialPageRoute(builder: (_) => const DoctorSettingsScreen()));
                    } else if (v == 'signout') {
                      api.logout();
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'profile', child: Text('Profile')),
                    PopupMenuItem(value: 'settings', child: Text('Settings')),
                    PopupMenuDivider(),
                    PopupMenuItem(value: 'signout', child: Text('Sign out')),
                  ],
                ),
              ],
            ],
          ),
          // A signed-in doctor lands on the practice dashboard, filling the
          // space below the bar and scrolling on its own. Visitors get the
          // full marketing pitch in a centred column.
          if (isDoctor)
            SliverFillRemaining(
              hasScrollBody: true,
              child: DoctorDashboardScreen(
                doctorName: api.doctorName ?? 'Doctor',
              ),
            )
          else
            SliverToBoxAdapter(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _Hero(),
                        const SizedBox(height: 28),
                        const _ActionButtons(),
                        const SizedBox(height: 40),
                        const _SectionTitle('Why Med-IC'),
                        const SizedBox(height: 12),
                        const _FeatureGrid(),
                        const SizedBox(height: 40),
                        const _SectionTitle('How it works'),
                        const SizedBox(height: 12),
                        const _HowItWorks(),
                        const SizedBox(height: 32),
                        const _Disclaimer(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Logo tile + wordmark: "Med" in white, "-IC" in brand blue.
class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: MedThruTheme.blue,
            borderRadius: BorderRadius.circular(9),
          ),
          child: const Icon(Icons.layers, size: 18, color: Colors.white),
        ),
        const SizedBox(width: 10),
        Text.rich(
          const TextSpan(
            children: [
              TextSpan(text: 'Med'),
              TextSpan(
                text: '-IC',
                style: TextStyle(color: MedThruTheme.blue),
              ),
            ],
          ),
          style: TextStyle(
            color: scheme.onSurface,
            fontSize: 20,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
          ),
        ),
      ],
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        // A faint green top-glow lifts the hero off the near-black page.
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(
                MedThruTheme.blue.withValues(alpha: 0.14), scheme.surfaceContainerLow),
            scheme.surfaceContainerLow,
          ],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Badge pill
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: MedThruTheme.blue.withValues(alpha: 0.55)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.nfc, size: 14, color: MedThruTheme.blue),
                SizedBox(width: 7),
                Text(
                  'NFC MEDICAL CARD',
                  style: TextStyle(
                    color: MedThruTheme.blue,
                    fontSize: 11,
                    letterSpacing: 1.1,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          // Headline with the last phrase highlighted in the brand green.
          Text.rich(
            const TextSpan(
              children: [
                TextSpan(text: 'Your medical card,\nreadable '),
                TextSpan(
                  text: 'in a tap',
                  style: TextStyle(color: MedThruTheme.blue),
                ),
                TextSpan(text: '.'),
              ],
            ),
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 34,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.8,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 16),
          // Short blue accent rule, like the reference design.
          Container(
            width: 64,
            height: 4,
            decoration: BoxDecoration(
              color: MedThruTheme.blue,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Med-IC turns an NFC card into a secure key to a patient\'s '
            'critical health information — blood type, allergies, medications '
            'and emergency contacts — available instantly to the people who '
            'need it, and updatable over time.',
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 15,
              height: 1.55,
            ),
          ),
        ],
      ),
    );
  }
}

/// The visitor call-to-action pair: log in with a phone, or sign in as a
/// doctor. (A signed-in doctor's actions live in the app bar instead.)
class _ActionButtons extends StatelessWidget {
  const _ActionButtons();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const PatientLoginScreen()),
          ),
          icon: const Icon(Icons.phone_iphone_outlined),
          label: const Text('Log in with phone'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const DoctorLoginScreen()),
          ),
          icon: const Icon(Icons.login),
          label: const Text('Doctor sign in'),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.bold,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }
}

class _FeatureGrid extends StatelessWidget {
  const _FeatureGrid();

  static const _features = [
    (
      Icons.bolt_outlined,
      'Instant access',
      'Critical patient data in seconds with a single NFC tap — no passwords, no delays.',
      MedThruTheme.tileBlue,
      MedThruTheme.iconBlue,
    ),
    (
      Icons.shield_outlined,
      'Secure & private',
      'Records live on the server, not the card. Lose a card and a doctor can '
          'revoke it instantly and issue a new one.',
      MedThruTheme.tileGreen,
      MedThruTheme.iconGreen,
    ),
    (
      Icons.favorite_outline,
      'Better emergency care',
      'Faster, informed decisions by paramedics and doctors mean fewer treatment errors.',
      MedThruTheme.tileRed,
      MedThruTheme.iconRed,
    ),
    (
      Icons.verified_user_outlined,
      'Fully audited',
      'Every read and edit is logged — who accessed what, and exactly when.',
      MedThruTheme.tilePurple,
      MedThruTheme.iconPurple,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final twoCols = constraints.maxWidth > 520;
        final cardWidth = twoCols
            ? (constraints.maxWidth - 14) / 2
            : constraints.maxWidth;
        return Wrap(
          spacing: 14,
          runSpacing: 14,
          children: [
            for (final (icon, title, body, tile, iconColor) in _features)
              SizedBox(
                width: cardWidth,
                child: _FeatureCard(
                  icon: icon,
                  title: title,
                  body: body,
                  tileColor: tile,
                  iconColor: iconColor,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.tileColor,
    required this.iconColor,
  });
  final IconData icon;
  final String title;
  final String body;
  final Color tileColor;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
        boxShadow: isDark
            ? null
            : [
                BoxShadow(
                  color: MedThruTheme.navy.withValues(alpha: 0.06),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Pastel tile behind the icon. On dark surfaces the pastel is too
          // bright, so tint it down and use the pastel for the icon instead.
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark ? iconColor.withValues(alpha: 0.18) : tileColor,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon,
                color: isDark ? tileColor : iconColor, size: 24),
          ),
          const SizedBox(height: 14),
          Text(title,
              style: TextStyle(
                  fontSize: 16.5,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface)),
          const SizedBox(height: 6),
          Text(body,
              style: TextStyle(
                  color: scheme.onSurfaceVariant, fontSize: 13.5, height: 1.5)),
        ],
      ),
    );
  }
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  static const _steps = [
    ('1', 'Tap the card', 'A patient taps their MedThru card on a reader or phone.'),
    ('2', 'Secure lookup', 'The card\'s token is matched to a record on the server.'),
    ('3', 'View or update', 'Patients see their record; doctors can update it safely.'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (final (num, title, body) in _steps)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: scheme.primary,
                  child: Text(num,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: 15.5, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(body,
                          style: TextStyle(
                              color: scheme.onSurfaceVariant, height: 1.4)),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Disclaimer extends StatelessWidget {
  const _Disclaimer();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Prototype — for demonstration only. Not yet for real patient data.',
              style: TextStyle(
                  color: scheme.onSurfaceVariant, fontSize: 12.5, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
