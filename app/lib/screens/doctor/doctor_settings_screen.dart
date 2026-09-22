import 'package:flutter/material.dart';
import '../../api.dart';
import '../../widgets.dart';
import 'contraindication_rules_screen.dart';

/// Doctor account settings: edit profile fields and change password.
class DoctorSettingsScreen extends StatefulWidget {
  const DoctorSettingsScreen({super.key});

  @override
  State<DoctorSettingsScreen> createState() => _DoctorSettingsScreenState();
}

class _DoctorSettingsScreenState extends State<DoctorSettingsScreen> {
  final _api = MedThruApi.instance;

  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  late Future<List<Map<String, dynamic>>> _clinics;
  int? _clinicId;
  bool _savingProfile = false;
  String? _profileError;

  final _currentPassword = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirmPassword = TextEditingController();
  bool _savingPassword = false;
  String? _passwordError;

  @override
  void initState() {
    super.initState();
    final doctor = _api.doctor;
    _name.text = doctor?['name'] as String? ?? '';
    _email.text = doctor?['email'] as String? ?? '';
    _phone.text = doctor?['phone'] as String? ?? '';
    _clinicId = doctor?['clinic_id'] as int?;
    _clinics = _api.getClinics();
    _clinics.ignore();
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    _currentPassword.dispose();
    _newPassword.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  Future<void> _saveProfile() async {
    if (_name.text.trim().isEmpty || _email.text.trim().isEmpty) {
      setState(() => _profileError = 'Name and email are required.');
      return;
    }
    setState(() {
      _savingProfile = true;
      _profileError = null;
    });
    try {
      await _api.updateDoctorProfile(
        name: _name.text.trim(),
        email: _email.text.trim(),
        phone: _phone.text.trim(),
        clinicId: _clinicId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile updated')),
      );
    } catch (e) {
      setState(() => _profileError = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _savingProfile = false);
    }
  }

  Future<void> _changePassword() async {
    if (_newPassword.text.length < 8) {
      setState(() => _passwordError = 'New password must be at least 8 characters.');
      return;
    }
    if (_newPassword.text != _confirmPassword.text) {
      setState(() => _passwordError = 'New passwords do not match.');
      return;
    }
    setState(() {
      _savingPassword = true;
      _passwordError = null;
    });
    try {
      await _api.changePassword(_currentPassword.text, _newPassword.text);
      if (!mounted) return;
      _currentPassword.clear();
      _newPassword.clear();
      _confirmPassword.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password changed')),
      );
    } catch (e) {
      setState(() => _passwordError = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _savingPassword = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: BoundedBody(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('Profile',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface)),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Name',
                prefixIcon: Icon(Icons.badge_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Email',
                prefixIcon: Icon(Icons.email_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Phone number',
                prefixIcon: Icon(Icons.phone_outlined),
              ),
            ),
            const SizedBox(height: 12),
            Text('Clinic',
                style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 6),
            FutureBuilder<List<Map<String, dynamic>>>(
              future: _clinics,
              builder: (context, snap) {
                final clinics = snap.data ?? const [];
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final c in clinics)
                      ChoiceChip(
                        label: Text(c['name'] as String),
                        selected: _clinicId == c['id'],
                        onSelected: (selected) =>
                            setState(() => _clinicId = selected ? c['id'] as int : null),
                      ),
                  ],
                );
              },
            ),
            if (_profileError != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.error_outline, size: 18, color: scheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_profileError!,
                        style: TextStyle(color: scheme.error)),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _savingProfile ? null : _saveProfile,
              icon: _savingProfile
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: Text(_savingProfile ? 'Saving…' : 'Save profile'),
            ),
            const SizedBox(height: 32),
            Divider(color: scheme.outlineVariant),
            const SizedBox(height: 20),
            Text('Change password',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface)),
            const SizedBox(height: 12),
            TextField(
              controller: _currentPassword,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Current password',
                prefixIcon: Icon(Icons.lock_outline),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _newPassword,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'New password',
                prefixIcon: Icon(Icons.lock_reset_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _confirmPassword,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Confirm new password',
                prefixIcon: Icon(Icons.lock_reset_outlined),
              ),
              onSubmitted: (_) => _changePassword(),
            ),
            if (_passwordError != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.error_outline, size: 18, color: scheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_passwordError!,
                        style: TextStyle(color: scheme.error)),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _savingPassword ? null : _changePassword,
              icon: _savingPassword
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.password_outlined),
              label: Text(_savingPassword ? 'Changing…' : 'Change password'),
            ),
            if (_api.isAdmin) ...[
              const SizedBox(height: 32),
              Divider(color: scheme.outlineVariant),
              const SizedBox(height: 20),
              Text('Administration',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface)),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ContraindicationRulesScreen()),
                ),
                icon: const Icon(Icons.rule_outlined),
                label: const Text('Contraindication rules'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
