import 'package:flutter/material.dart';
import '../../api.dart';
import '../../health_record_widgets.dart' show EmergencyContactCard;
import '../../pdf_export.dart';
import '../../readings.dart';
import '../../theme.dart';
import '../../trend_chart.dart' show longDate, Sparkline;
import '../../widgets.dart';
import 'edit_patient_screen.dart';
import 'edit_profile_screen.dart';
import '../doctor/audit_screen.dart';
import '../health_records/add_reading_screen.dart';
import 'appointments_screen.dart';
import 'appointment_calendar.dart';
import 'activity_recap.dart';
import 'care_plan_screen.dart';
import 'clinical_updates_screen.dart';
import '../messages/conversation_screen.dart';
import 'health_records_menu_screen.dart';
import '../health_records/health_record_list_screen.dart';

/// A patient's record, split into tabs reachable from a bottom nav bar so
/// neither a patient nor a doctor has to scroll one long page to find things.
class PatientScreen extends StatefulWidget {
  const PatientScreen({
    super.key,
    required this.patient,
    required this.cardToken,
    this.unlockPassword,
    this.today,
  });

  /// Pins the day the Home tab's calendar treats as "today". Real sessions
  /// leave this null and follow the clock; tests set it so the dashboard
  /// renders the same month every run.
  final DateTime? today;

  final Map<String, dynamic> patient;

  /// Held in memory only, to prove card possession when writing readings.
  /// Never rendered — the UI shows `card_preview` instead.
  final String cardToken;

  /// Set only when this card required its password to open (see
  /// `resolveTappedPatient` in main.dart). Re-sent on every refresh so the
  /// screen doesn't have to re-prompt for the rest of this visit — null for
  /// a doctor session or a patient who hasn't set a card password up.
  final String? unlockPassword;

  @override
  State<PatientScreen> createState() => _PatientScreenState();
}

class _PatientScreenState extends State<PatientScreen>
    with SingleTickerProviderStateMixin {
  late Map<String, dynamic> _patient;
  late final TabController _tabs;

  // Tab index for Emergency — the only tab the FAB still needs to check.
  // Care plan, Appointments, Health records and Updates moved out to
  // Home-dashboard-only pushed screens; Profile and Settings need no FAB.
  static const _tabEmergency = 2;

  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _patient = widget.patient;
    _tabs = TabController(length: 4, vsync: this);
    // Rebuild so the floating action button matches the visible tab.
    _tabs.addListener(() {
      if (!_tabs.indexIsChanging) setState(() {});
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  /// Re-fetch the patient record from the server. Notes, appointments and
  /// health records each own their fetch now, inside their own pushed screen.
  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    try {
      final fresh = await MedThruApi.instance.lookupByToken(
        widget.cardToken,
        password: widget.unlockPassword,
      );
      if (!mounted) return;
      setState(() {
        if (fresh != null) _patient = fresh;
      });
    } on PasswordRequiredException {
      // The password must have changed since this screen opened — nothing
      // graceful to do mid-visit beyond saying so; the next tap will
      // re-prompt with the new one.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not refresh: this card\'s password has changed.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  String _val(String key) {
    final v = _patient[key];
    return (v == null || (v is String && v.isEmpty)) ? '—' : v.toString();
  }

  bool _has(String key) {
    final v = _patient[key];
    return v != null && !(v is String && v.isEmpty);
  }

  Future<void> _edit() async {
    final updated = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            EditPatientScreen(patient: _patient, cardToken: widget.cardToken),
      ),
    );
    if (updated != null && mounted) {
      setState(() => _patient = updated);
    }
  }

  /// A patient correcting their own name or date of birth. Open to patients,
  /// not doctors — clinical fields stay behind [_edit] instead.
  Future<void> _editProfile() async {
    final updated = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            EditProfileScreen(token: widget.cardToken, patient: _patient),
      ),
    );
    if (updated != null && mounted) {
      setState(() => _patient = updated);
    }
  }

  /// Lost card: revoke the old token and issue a new one. The replacement is
  /// shown once so it can be written to a blank card.
  Future<void> _reissueCard() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.credit_card_off_outlined),
        title: const Text('Reissue card?'),
        content: Text(
          'The current card (*******${_patient['card_preview'] ?? '????'}) will '
          'stop working immediately. A new token will be issued for '
          '${_val('full_name')}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(minimumSize: const Size(120, 42)),
            child: const Text('Reissue'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final result = await MedThruApi.instance.reissueCard(
        _patient['id'] as int,
      );
      if (!mounted) return;
      await showCardTokenDialog(
        context,
        token: result.cardToken,
        patientName: result.patient['full_name'] as String,
        isReissue: true,
      );
      if (!mounted) return;
      // The old token this screen holds is now dead; restart on the new card.
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => PatientScreen(
            patient: result.patient,
            cardToken: result.cardToken,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  /// Open to patients, not just doctors. A general-purpose shortcut from the
  /// Home dashboard; category-scoped adds live inside each Health Records
  /// category page instead.
  Future<void> _addReading() async {
    await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => AddReadingScreen(token: widget.cardToken),
      ),
    );
  }

  /// Care plan is a pushed screen now, since it's no longer a tab. Refresh
  /// afterwards in case a doctor edited clinical fields while there.
  Future<void> _openCarePlan(bool isDoctor) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CarePlanScreen(
          patient: _patient,
          cardToken: widget.cardToken,
          isDoctor: isDoctor,
        ),
      ),
    );
    if (mounted) await _refresh();
  }

  Future<void> _openAppointments() {
    return Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AppointmentsScreen(cardToken: widget.cardToken),
      ),
    );
  }

  Future<void> _openHealthRecords() {
    return Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => HealthRecordsMenuScreen(
          patientId: _patient['id'] as int,
          cardToken: widget.cardToken,
        ),
      ),
    );
  }

  Future<void> _openMessages() {
    return Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ConversationScreen(cardToken: widget.cardToken, title: 'Messages'),
      ),
    );
  }

  Future<void> _openUpdates(bool isDoctor) {
    return Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ClinicalUpdatesScreen(
          patientId: _patient['id'] as int,
          isDoctor: isDoctor,
        ),
      ),
    );
  }

  /// Bind phone + password to this card so the patient can sign in later
  /// without it. Only offered while holding a real card (not a "me" session,
  /// which has nothing to prove possession with) and not to a doctor
  /// browsing on the patient's behalf.
  Future<void> _setupPhoneLogin() async {
    final existingPhone = _patient['phone'] as String?;
    final isUpdate = existingPhone != null && existingPhone.isNotEmpty;
    final phone = TextEditingController(text: existingPhone ?? '');
    final password = TextEditingController();
    String? error;

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          icon: const Icon(Icons.phone_iphone_outlined),
          title: Text(isUpdate ? 'Update phone login' : 'Set up phone login'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Lets you sign in with a phone number and password later, '
                'without your card.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12.5,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Phone number'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: password,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: isUpdate ? 'New password' : 'Password',
                  helperText: isUpdate
                      ? 'Re-enter a password even if only the phone number changed.'
                      : null,
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 10),
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  await MedThruApi.instance.setupPatientLogin(
                    widget.cardToken,
                    phone.text.trim(),
                    password.text,
                  );
                  if (context.mounted) Navigator.pop(context, true);
                } catch (e) {
                  setDialogState(
                    () => error = e.toString().replaceFirst('Exception: ', ''),
                  );
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (ok == true && mounted) {
      // The dialog only changed the phone/password on the server; reload so
      // the Profile tab actually reflects the new phone number.
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isUpdate ? 'Phone login updated.' : 'Phone login is set up.',
          ),
        ),
      );
    }
  }

  /// End a phone-login session and return to the home screen. Only offered
  /// when this screen was reached with "me" — a real card has nothing to
  /// "sign out" of.
  void _signOut() {
    MedThruApi.instance.patientLogout();
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  /// The tab strip, with the little mascot tucked in right after the
  /// Settings tab. Wrapped so the tabs and cat sit together, centred.
  PreferredSizeWidget _tabBarWithMascot(BuildContext context) {
    final tabBar = TabBar(
      controller: _tabs,
      isScrollable: true,
      tabAlignment: TabAlignment.center,
      dividerColor: Colors.transparent,
      indicator: BoxDecoration(
        color: MedThruTheme.blue,
        borderRadius: BorderRadius.circular(20),
      ),
      indicatorSize: TabBarIndicatorSize.label,
      indicatorPadding: const EdgeInsets.symmetric(vertical: 6),
      labelPadding: const EdgeInsets.symmetric(horizontal: 16),
      splashBorderRadius: BorderRadius.circular(20),
      labelColor: Colors.white,
      unselectedLabelColor: Theme.of(context).colorScheme.onSurfaceVariant,
      labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
      unselectedLabelStyle: const TextStyle(
        fontWeight: FontWeight.w600,
        fontSize: 13,
      ),
      tabs: const [
        Tab(icon: Icon(Icons.home_outlined), text: 'Home'),
        Tab(icon: Icon(Icons.person_outline), text: 'Profile'),
        Tab(icon: Icon(Icons.emergency_outlined), text: 'Emergency'),
        Tab(icon: Icon(Icons.settings_outlined), text: 'Settings'),
      ],
    );
    return PreferredSize(
      preferredSize: tabBar.preferredSize,
      // Mirror the body's 640-wide centred column so the mascot can be pinned
      // to the same right edge as the identity card's Refresh button
      // (16px list padding + 18px card padding in from the column edge).
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Stack(
            alignment: Alignment.center,
            children: [
              tabBar,
              Positioned(
                right: 34,
                child: Image.asset(
                  'assets/images/cat.png',
                  width: 30,
                  height: 30,
                  fit: BoxFit.contain,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDoctor = MedThruApi.instance.isLoggedIn;
    final isAdmin = MedThruApi.instance.isAdmin;

    final tabs = [
      _HomeTab(
        patient: _patient,
        cardToken: widget.cardToken,
        val: _val,
        has: _has,
        refreshing: _refreshing,
        onRefresh: _refresh,
        onAddReading: _addReading,
        onOpenEmergency: () => _tabs.animateTo(_tabEmergency),
        onOpenCarePlan: () => _openCarePlan(isDoctor),
        onOpenAppointments: _openAppointments,
        onOpenHealthRecords: _openHealthRecords,
        onOpenUpdates: () => _openUpdates(isDoctor),
        onOpenMessages: _openMessages,
        today: widget.today,
      ),
      _ProfileTab(
        val: _val,
        has: _has,
        canEditProfile: !isDoctor,
        onEditProfile: _editProfile,
      ),
      _EmergencyTab(
        patient: _patient,
        val: _val,
        has: _has,
        patientId: _patient['id'] as int,
        cardToken: widget.cardToken,
      ),
      _SettingsTab(
        patient: _patient,
        has: _has,
        val: _val,
        isDoctor: isDoctor,
        canSetupPhoneLogin: !isDoctor && widget.cardToken != 'me',
        onSetupPhoneLogin: _setupPhoneLogin,
        onSignOut: widget.cardToken == 'me' ? _signOut : null,
      ),
    ];

    // In a patient's own phone-login ("me") session there's nothing to go
    // back to — Home is the root — so drop the back arrow and let them leave
    // via Sign out instead. Doctors and card-tap sessions keep it to return.
    final isSelfSession = widget.cardToken == 'me';

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !isSelfSession,
        // A doctor or card-tap session needs to see whose record is open; a
        // patient's own session doesn't need their name echoed back to them.
        title: isSelfSession ? null : Text(_val('full_name')),
        actions: [
          if (isDoctor) ...[
            if (isAdmin)
              IconButton(
                tooltip: 'Reissue card (lost or stolen)',
                icon: const Icon(Icons.credit_card_off_outlined),
                onPressed: _reissueCard,
              ),
            IconButton(
              tooltip: 'Access history',
              icon: const Icon(Icons.history),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AuditScreen(
                    patientId: _patient['id'] as int,
                    patientName: _val('full_name'),
                  ),
                ),
              ),
            ),
          ],
        ],
        bottom: _tabBarWithMascot(context),
      ),
      body: BoundedBody(
        maxWidth: 640,
        child: TabBarView(controller: _tabs, children: tabs),
      ),
      floatingActionButton: _buildFab(isDoctor),
    );
  }

  /// Emergency is the only remaining tab with a full clinical edit — Care
  /// plan carries its own "Edit record" FAB now that it's a pushed screen.
  Widget? _buildFab(bool isDoctor) {
    if (!isDoctor || _tabs.index != _tabEmergency) return null;
    return FloatingActionButton.extended(
      onPressed: _edit,
      icon: const Icon(Icons.edit),
      label: const Text('Edit record'),
    );
  }
}

// --- Tabs ---

/// Patient dashboard: identity card, quick actions, primary CTA.
class _HomeTab extends StatefulWidget {
  const _HomeTab({
    required this.patient,
    required this.cardToken,
    required this.val,
    required this.has,
    required this.refreshing,
    required this.onRefresh,
    required this.onAddReading,
    required this.onOpenEmergency,
    required this.onOpenCarePlan,
    required this.onOpenAppointments,
    required this.onOpenHealthRecords,
    required this.onOpenUpdates,
    required this.onOpenMessages,
    this.today,
  });

  final Map<String, dynamic> patient;
  final String cardToken;
  final String Function(String) val;
  final bool Function(String) has;
  final bool refreshing;
  final VoidCallback onRefresh;
  final Future<void> Function() onAddReading;
  final VoidCallback onOpenEmergency;
  final VoidCallback onOpenCarePlan;
  final Future<void> Function() onOpenAppointments;
  final Future<void> Function() onOpenHealthRecords;
  final VoidCallback onOpenUpdates;
  final VoidCallback onOpenMessages;
  final DateTime? today;

  @override
  State<_HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<_HomeTab> {
  late Future<List<Map<String, dynamic>>> _readings;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _readings = MedThruApi.instance.getReadings(widget.patient['id'] as int);
    _readings.ignore();
  }

  Future<void> _addReading() async {
    await widget.onAddReading();
    if (mounted) setState(_load);
  }

  Future<void> _openHealthRecords() async {
    await widget.onOpenHealthRecords();
    if (mounted) setState(_load);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final patient = widget.patient;
    final val = widget.val;
    final has = widget.has;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        _IdentityCard(
          name: val('full_name'),
          dob: val('date_of_birth'),
          bloodType: val('blood_type'),
          updatedAt: patient['updated_at'] as String?,
          refreshing: widget.refreshing,
          onRefresh: widget.onRefresh,
        ),
        const SizedBox(height: 10),
        Center(
          child: Text(
            'Tap your card on a reader to refresh',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 18),
        // Signature element: the one loud thing on an otherwise calm screen.
        EmergencyBand(onTap: widget.onOpenEmergency),
        const SizedBox(height: 18),
        if (has('allergies'))
          _AllergyBanner(allergies: patient['allergies'] as String),

        // "Your activity": the weekly recap. Day-by-day logging activity lives
        // on the appointment calendar below (each day shaded by readings-that-
        // day), so there's no separate heatmap card here.
        FutureBuilder<List<Map<String, dynamic>>>(
          future: _readings,
          builder: (context, snap) {
            final readings = snap.data;
            if (readings == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: ActivityRecapCard(readings: readings),
            );
          },
        ),

        FutureBuilder<List<Map<String, dynamic>>>(
          future: _readings,
          builder: (context, snap) {
            final readings = snap.data;
            if (readings == null)
              return const SizedBox.shrink(); // loading or failed
            return Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: _VitalsSnapshot(
                readings: readings,
                onTap: _openHealthRecords,
                onAddReading: _addReading,
              ),
            );
          },
        ),

        // Month-at-a-glance calendar: appointments as dots, each day shaded by
        // that day's logging activity. The full Appointments screen (book /
        // cancel / remind) is one tap away.
        FutureBuilder<List<Map<String, dynamic>>>(
          future: _readings,
          builder: (context, snap) => AppointmentCalendarCard(
            cardToken: widget.cardToken,
            readings: snap.data ?? const [],
            onOpenAll: widget.onOpenAppointments,
            today: widget.today,
          ),
        ),
        const SizedBox(height: 18),

        // Quick actions, two per row. (Emergency lives in the band above, so
        // it isn't repeated here.)
        Row(
          children: [
            Expanded(
              child: ActionTile(
                icon: Icons.medical_information_outlined,
                label: 'Health Records',
                color: MedThruTheme.iconBlue,
                tile: MedThruTheme.tileBlue,
                onTap: _openHealthRecords,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ActionTile(
                icon: Icons.event_outlined,
                label: 'Care Plan',
                color: MedThruTheme.iconGreen,
                tile: MedThruTheme.tileGreen,
                onTap: widget.onOpenCarePlan,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: ActionTile(
                icon: Icons.timeline_outlined,
                label: 'Clinical Updates',
                color: MedThruTheme.iconPurple,
                tile: MedThruTheme.tilePurple,
                onTap: widget.onOpenUpdates,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ActionTile(
                icon: Icons.calendar_month_outlined,
                label: 'Appointments',
                color: MedThruTheme.iconBlue,
                tile: MedThruTheme.tileBlue,
                onTap: widget.onOpenAppointments,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ActionTile(
          icon: Icons.forum_outlined,
          label: 'Messages',
          color: MedThruTheme.iconGreen,
          tile: MedThruTheme.tileGreen,
          onTap: widget.onOpenMessages,
        ),
        const SizedBox(height: 22),
        FilledButton.icon(
          onPressed: _addReading,
          icon: const Icon(Icons.add),
          label: const Text('Add a reading'),
        ),
      ],
    );
  }
}

/// Personal details: name and date of birth.
class _ProfileTab extends StatelessWidget {
  const _ProfileTab({
    required this.val,
    required this.has,
    required this.canEditProfile,
    required this.onEditProfile,
  });

  final String Function(String) val;
  final bool Function(String) has;
  final bool canEditProfile;
  final VoidCallback onEditProfile;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        _TabHeading(
          icon: Icons.person_outline,
          title: 'Profile',
          subtitle: 'Personal and medical details.',
        ),
        FieldCard(
          label: 'Full name',
          value: val('full_name'),
          icon: Icons.badge_outlined,
        ),
        FieldCard(
          label: 'Date of birth',
          value: val('date_of_birth'),
          icon: Icons.cake_outlined,
        ),
        if (canEditProfile) ...[
          const SizedBox(height: 4),
          OutlinedButton.icon(
            onPressed: onEditProfile,
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('Edit name / date of birth'),
          ),
        ],
        const SizedBox(height: 26),
        Text(
          'MEDICAL DETAILS',
          style: TextStyle(
            fontSize: 12,
            letterSpacing: 1,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        FieldCard(
          label: 'Blood type',
          value: val('blood_type'),
          icon: Icons.bloodtype_outlined,
        ),
        FieldCard(
          label: 'Allergies',
          value: val('allergies'),
          icon: Icons.warning_amber_outlined,
        ),
        FieldCard(
          label: 'Medications',
          value: val('medications'),
          icon: Icons.medication_outlined,
        ),
        FieldCard(
          label: 'Conditions',
          value: val('conditions'),
          icon: Icons.monitor_heart_outlined,
        ),
      ],
    );
  }
}

/// How you sign in, and account-level actions. Kept apart from Profile —
/// Profile is "who you are", Settings is "how you access this app".
class _SettingsTab extends StatelessWidget {
  const _SettingsTab({
    required this.patient,
    required this.val,
    required this.has,
    required this.isDoctor,
    required this.canSetupPhoneLogin,
    required this.onSetupPhoneLogin,
    required this.onSignOut,
  });

  final Map<String, dynamic> patient;
  final String Function(String) val;
  final bool Function(String) has;
  final bool isDoctor;
  final bool canSetupPhoneLogin;
  final VoidCallback onSetupPhoneLogin;
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (isDoctor) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          _TabHeading(
            icon: Icons.settings_outlined,
            title: 'Settings',
            subtitle: 'Account settings for this record.',
          ),
          Text(
            'Your own account settings are on the home screen, under your '
            'profile menu — not tied to any one patient\'s record.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ],
      );
    }

    final phoneLoginSetUp = has('phone');
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        _TabHeading(
          icon: Icons.settings_outlined,
          title: 'Settings',
          subtitle: 'How you sign in to this record.',
        ),
        Text(
          'SIGN-IN',
          style: TextStyle(
            fontSize: 12,
            letterSpacing: 1,
            fontWeight: FontWeight.w700,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        FieldCard(
          label: 'Phone number',
          value: phoneLoginSetUp ? val('phone') : 'Not set up',
          icon: Icons.phone_outlined,
        ),
        if (canSetupPhoneLogin) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                phoneLoginSetUp
                    ? Icons.check_circle_outline
                    : Icons.info_outline,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  phoneLoginSetUp
                      ? 'You can sign in with this phone number and password '
                            'without your card.'
                      : 'Set up a phone number and password so you can sign '
                            'in without your card.',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: onSetupPhoneLogin,
            icon: Icon(
              phoneLoginSetUp
                  ? Icons.phone_iphone_outlined
                  : Icons.add_ic_call_outlined,
            ),
            label: Text(
              phoneLoginSetUp ? 'Update phone login' : 'Set up phone login',
            ),
          ),
        ],
        if (onSignOut != null) ...[
          const SizedBox(height: 24),
          Divider(color: scheme.outlineVariant),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onSignOut,
            icon: Icon(Icons.logout, color: scheme.error),
            label: Text('Sign out', style: TextStyle(color: scheme.error)),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: scheme.error),
            ),
          ),
        ],
      ],
    );
  }
}

/// The hero card: who this is, and the one fact an emergency responder needs.
class _IdentityCard extends StatelessWidget {
  const _IdentityCard({
    required this.name,
    required this.dob,
    required this.bloodType,
    required this.updatedAt,
    required this.refreshing,
    required this.onRefresh,
  });

  final String name, dob, bloodType;
  final String? updatedAt;
  final bool refreshing;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return GradientHeroCard(
      name: name,
      subtitle: dob == '—' ? 'Date of birth not set' : 'Born $dob',
      trailing: refreshing
          ? const SizedBox(
              height: 16,
              width: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : InkWell(
              onTap: onRefresh,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Text(
                  'Refresh',
                  style: TextStyle(
                    color: MedThruTheme.blue,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: MedThruTheme.danger.withValues(alpha: 0.16),
              shape: BoxShape.circle,
              border: Border.all(
                color: MedThruTheme.danger.withValues(alpha: 0.4),
              ),
            ),
            child: const Icon(
              Icons.bloodtype_outlined,
              size: 30,
              color: MedThruTheme.danger,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            bloodType == '—' ? 'Blood type unknown' : 'Blood Type  $bloodType',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 24,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            updatedAt == null ? '' : 'Updated ${_pretty(updatedAt!)}',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 11.5,
            ),
          ),
        ],
      ),
    );
  }

  static String _pretty(String sqlTimestamp) {
    final t = DateTime.tryParse(sqlTimestamp);
    if (t == null) return sqlTimestamp;
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '${longDate(t)}, $hh:$mm';
  }
}

class _EmergencyTab extends StatefulWidget {
  const _EmergencyTab({
    required this.patient,
    required this.val,
    required this.has,
    required this.patientId,
    required this.cardToken,
  });
  final Map<String, dynamic> patient;
  final String Function(String) val;
  final bool Function(String) has;
  final int patientId;
  final String cardToken;

  @override
  State<_EmergencyTab> createState() => _EmergencyTabState();
}

class _EmergencyTabState extends State<_EmergencyTab> {
  late Future<List<Map<String, dynamic>>> _contacts;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _contacts = MedThruApi.instance.getEmergencyContactsForPatient(
      widget.patientId,
    );
    _contacts.ignore();
  }

  Future<void> _manageContacts() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => HealthRecordListScreen(
          patientId: widget.patientId,
          cardToken: widget.cardToken,
          config: emergencyContactRecordConfig,
        ),
      ),
    );
    // Contacts may have changed while that screen was open — refresh the
    // preview whether or not anything was actually edited.
    if (mounted) setState(_load);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        _TabHeading(
          icon: Icons.emergency_outlined,
          title: 'Emergency info',
          subtitle: 'The essentials a first responder needs, up front.',
        ),
        OutlinedButton.icon(
          onPressed: () => exportPatientSummary(context, widget.patient),
          icon: const Icon(Icons.picture_as_pdf_outlined),
          label: const Text('Export emergency summary (PDF)'),
        ),
        const SizedBox(height: 22),
        // The two things that matter most in an emergency, made large.
        Row(
          children: [
            Expanded(
              child: _BigStat(
                label: 'Blood type',
                value: widget.val('blood_type'),
                color: MedThruTheme.iconRed,
                tile: MedThruTheme.tileRed,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _BigStat(
                label: 'Allergies',
                value: widget.val('allergies'),
                color: MedThruTheme.iconRed,
                tile: MedThruTheme.tileRed,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        FieldCard(
          label: 'Conditions',
          value: widget.val('conditions'),
          icon: Icons.monitor_heart_outlined,
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Text(
              'EMERGENCY CONTACTS',
              style: TextStyle(
                fontSize: 12,
                letterSpacing: 1,
                fontWeight: FontWeight.w700,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _manageContacts,
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('Manage'),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            ),
          ],
        ),
        const SizedBox(height: 4),
        FutureBuilder<List<Map<String, dynamic>>>(
          future: _contacts,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snap.hasError) {
              return Text(
                snap.error.toString().replaceFirst('Exception: ', ''),
                style: TextStyle(color: scheme.error, fontSize: 13),
              );
            }
            final contacts = snap.data ?? [];
            if (contacts.isEmpty) {
              return GestureDetector(
                onTap: _manageContacts,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'No emergency contacts added yet. Tap to add one.',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              );
            }
            return Column(
              children: [
                for (final c in contacts) EmergencyContactCard(row: c),
              ],
            );
          },
        ),
      ],
    );
  }
}

// --- Shared pieces ---

class _TabHeading extends StatelessWidget {
  const _TabHeading({
    required this.icon,
    required this.title,
    required this.subtitle,
  });
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: scheme.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  color: scheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13.5),
          ),
        ],
      ),
    );
  }
}

class _BigStat extends StatelessWidget {
  const _BigStat({
    required this.label,
    required this.value,
    required this.color,
    required this.tile,
  });
  final String label;
  final String value;
  final Color color;
  final Color tile;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? color.withValues(alpha: 0.16) : tile,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 1,
              fontWeight: FontWeight.w700,
              color: isDark ? tile : color,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _AllergyBanner extends StatelessWidget {
  const _AllergyBanner({required this.allergies});
  final String allergies;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: MedThruTheme.danger.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: MedThruTheme.danger.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber, color: MedThruTheme.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Allergies: $allergies',
              style: const TextStyle(
                color: MedThruTheme.danger,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "How am I doing" at a glance: the latest value for each vital sign that's
/// actually been logged, so a patient sees it on Home instead of needing a
/// trip into Health Records. Deliberately just the latest reading per
/// metric, not the full trend chart — that stays one tap away, since this is
/// a snapshot layer, not a replacement for it. Anthropometry (height/weight)
/// is left out: it's not what "vital signs" means to someone checking in
/// day to day.
class _VitalsSnapshot extends StatelessWidget {
  const _VitalsSnapshot({
    required this.readings,
    required this.onTap,
    required this.onAddReading,
  });

  /// All of the patient's readings, newest first.
  final List<Map<String, dynamic>> readings;
  final VoidCallback onTap;
  final Future<void> Function() onAddReading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // First occurrence per type wins, since `readings` is newest-first.
    final latestByType = <String, Map<String, dynamic>>{};
    for (final r in readings) {
      final type = r['reading_type'] as String?;
      if (type == null ||
          readingTypes[type]?.category != ReadingCategory.vital) {
        continue;
      }
      latestByType.putIfAbsent(type, () => r);
    }

    final specs = readingTypes.values
        .where(
          (t) =>
              t.category == ReadingCategory.vital &&
              latestByType.containsKey(t.key),
        )
        .toList();

    // Each metric's own values, oldest-to-newest, for its sparkline. `readings`
    // is newest-first, so reverse; keep the most recent dozen for a legible line.
    List<double> seriesFor(String type) {
      final vals = <double>[];
      for (final r in readings.reversed) {
        if (r['reading_type'] == type && r['value'] is num) {
          vals.add((r['value'] as num).toDouble());
        }
      }
      return vals.length > 12 ? vals.sublist(vals.length - 12) : vals;
    }

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: latestByType.isEmpty ? onAddReading : onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: scheme.outlineVariant),
          boxShadow: MedThruTheme.softShadow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'VITAL SIGNS',
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 1,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Add a reading',
                  icon: const Icon(Icons.add_circle_outline, size: 20),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: onAddReading,
                ),
                if (latestByType.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            if (latestByType.isEmpty)
              Text(
                'No vitals logged yet — tap to add your first reading.',
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                ),
              )
            else
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final spec in specs)
                    _VitalChip(
                      spec: spec,
                      reading: latestByType[spec.key]!,
                      series: seriesFor(spec.key),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _VitalChip extends StatelessWidget {
  const _VitalChip({
    required this.spec,
    required this.reading,
    required this.series,
  });
  final ReadingType spec;
  final Map<String, dynamic> reading;

  /// This metric's values oldest-to-newest, for the trend sparkline.
  final List<double> series;

  @override
  Widget build(BuildContext context) {
    final value = reading['value'] as num;
    final within = spec.withinTypical(value);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      constraints: const BoxConstraints(minWidth: 100),
      decoration: BoxDecoration(
        color: spec.tile(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(spec.icon, size: 13, color: spec.color(context)),
              const SizedBox(width: 4),
              Text(
                spec.label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: spec.color(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${spec.format(value)} ${spec.unit}',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
          if (within != null) ...[
            const SizedBox(height: 2),
            Text(
              within ? 'within range' : 'out of range',
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
                color: within ? MedThruTheme.iconGreen : MedThruTheme.danger,
              ),
            ),
          ],
          // The trend at a glance — only once there are enough points to draw a
          // line; a single reading has no trend to show.
          if (series.length >= 2) ...[
            const SizedBox(height: 6),
            Sparkline(
              values: series,
              color: spec.color(context),
              low: spec.low,
              high: spec.high,
              width: 96,
              height: 24,
            ),
          ],
        ],
      ),
    );
  }
}
