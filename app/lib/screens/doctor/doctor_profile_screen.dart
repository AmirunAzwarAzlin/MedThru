import 'package:flutter/material.dart';
import '../../api.dart';
import '../../theme.dart';
import '../../widgets.dart';
import 'doctor_settings_screen.dart';

/// Read-only glance at the signed-in doctor's account. Editing happens in
/// Settings; this is just the profile view.
class DoctorProfileScreen extends StatefulWidget {
  const DoctorProfileScreen({super.key});

  @override
  State<DoctorProfileScreen> createState() => _DoctorProfileScreenState();
}

class _DoctorProfileScreenState extends State<DoctorProfileScreen> {
  late Future<Map<String, dynamic>> _profile;

  @override
  void initState() {
    super.initState();
    _profile = MedThruApi.instance.getDoctorProfile();
  }

  String _memberSince(String? createdAt) {
    if (createdAt == null) return '—';
    final parsed = DateTime.tryParse(createdAt.replaceFirst(' ', 'T'));
    if (parsed == null) return createdAt;
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[parsed.month - 1]} ${parsed.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: BoundedBody(
        child: FutureBuilder<Map<String, dynamic>>(
          future: _profile,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return CenteredMessage(
                icon: Icons.error_outline,
                title: 'Could not load profile',
                subtitle: snap.error.toString().replaceFirst('Exception: ', ''),
              );
            }
            final doctor = snap.data!;
            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // Same gradient hero header as the patient Home tab's
                // identity card, so the doctor side reads as one app.
                GradientHeroCard(
                  name: doctor['name'] as String? ?? '—',
                  subtitle: doctor['is_admin'] == true ? 'Administrator' : 'Doctor',
                  child: doctor['is_admin'] != true
                      ? null
                      : Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: MedThruTheme.blue.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                                color: MedThruTheme.blue.withValues(alpha: 0.4)),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.shield_outlined,
                                  size: 14, color: MedThruTheme.blueBright),
                              SizedBox(width: 5),
                              Text(
                                'Administrator',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: MedThruTheme.blueBright,
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
                const SizedBox(height: 24),
                FieldCard(
                  label: 'Email',
                  value: doctor['email'] as String? ?? '—',
                  icon: Icons.email_outlined,
                ),
                FieldCard(
                  label: 'Phone number',
                  value: (doctor['phone'] as String?)?.isNotEmpty == true
                      ? doctor['phone'] as String
                      : '—',
                  icon: Icons.phone_outlined,
                ),
                FieldCard(
                  label: 'License number',
                  value: doctor['license_number'] as String? ?? '—',
                  icon: Icons.verified_outlined,
                ),
                FieldCard(
                  label: 'Doctor since',
                  value: _memberSince(doctor['created_at'] as String?),
                  icon: Icons.calendar_today_outlined,
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const DoctorSettingsScreen()),
                  ),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Edit in Settings'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
