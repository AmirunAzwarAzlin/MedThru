# Responder Home Screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Emergency Response Team accounts a landing screen suited to
what they do (scan a card, recall recently-viewed patients) instead of the
clinic practice dashboard (scheduling, KPIs, demographics) they currently
see.

**Architecture:** Add a `role` column to `doctors` (`'clinic'` default,
`'responder'` for EMS accounts), expose it through the existing doctor
profile response, add one new read endpoint that reuses existing audit-log
rows to answer "which patients has this doctor recently looked up," and
branch the existing `home_screen.dart` between the current
`DoctorDashboardScreen` and a new, much simpler `ResponderHomeScreen` based
on that role.

**Tech Stack:** Node.js + `node:sqlite` (backend, `server.js`/`db.js`),
Flutter/Dart (`app/lib`).

## Global Constraints

- `doctors.role` allowed values are `'clinic'` | `'responder'`, default
  `'clinic'`. No CHECK constraint — validated in application code only,
  matching how `rule_type`/`source`/etc. are already handled in this schema.
- This is a UI/landing-screen change, not a permissions wall. No new
  server-side role checks are added to any existing doctor-only endpoint.
- `POST /api/auth/register-doctor` keeps defaulting new accounts to
  `'clinic'` — there is no self-serve "I'm a responder" signup path.
- The new responder screen is scan-first only — no manual search/lookup
  fallback.
- `GET /api/doctor/recent-lookups` is available to any doctor account
  (not gated on role) — it's a generically useful query; the responder
  screen is just its first consumer.
- This Flutter codebase has no widget-test harness (established project
  convention — see `docs/superpowers/specs/2026-09-23-contraindication-bypass-enforcement-design.md`'s
  Testing section). Flutter tasks below are verified with `flutter analyze`
  plus a concrete manual walkthrough, not a red/green unit test.

---

## File Structure

- **Modify `db.js`**: one guarded migration block adding `doctors.role`.
- **Modify `server.js`**: `doctorProfile()` gains `role`; one new route,
  `GET /api/doctor/recent-lookups`.
- **Modify `seed-demo-data.js`**: the shared `insertDoctor` statement gains
  a `role` column; clinic doctors pass `'clinic'`, EMS responders pass
  `'responder'`.
- **Modify `test/smoke.js`**: two new self-contained test blocks (role
  defaulting/profile exposure; recent-lookups dedup + isolation).
- **Modify `app/lib/api.dart`**: `doctorRole` getter; `getRecentLookups()`
  method.
- **Modify `app/lib/screens/home_screen.dart`**: branch app-bar actions and
  body on `isResponder`.
- **Create `app/lib/screens/responder/responder_home_screen.dart`**: the
  new landing screen (self-contained — see Task 5 for why it doesn't share
  `doctor_dashboard_screen.dart`'s private `_Panel`/`_Greeting` widgets).

---

### Task 1: `doctors.role` column, exposed on the doctor profile

**Files:**
- Modify: `db.js:359-365` (insert a new migration block right after the
  existing `clinic_id` migration)
- Modify: `server.js:198-209` (`doctorProfile()`)
- Modify: `seed-demo-data.js:62-95` (`insertDoctor` statement and its two
  call sites)
- Test: `test/smoke.js` (new block before `console.log('\nAll smoke checks
  passed.');`, currently line 874)

**Interfaces:**
- Produces: `doctors.role` column (`TEXT NOT NULL DEFAULT 'clinic'`).
  `doctorProfile(doctor)` response objects gain a `role: string` field.
  Login (`POST /api/auth/login`), registration
  (`POST /api/auth/register-doctor`), and `GET /api/auth/me` all return this
  via `doctorProfile()`, so no separate wiring is needed for those routes.

- [ ] **Step 1: Write the failing test**

In `test/smoke.js`, insert this block right before the final
`console.log('\nAll smoke checks passed.');` line:

```js
    // --- Doctor role: defaults to 'clinic'; EMS-style accounts can be
    // provisioned directly as 'responder' ---
    res = await fetch(`${BASE}/auth/me`, { headers: { Authorization: `Bearer ${token}` } });
    assert(res.status === 200, 'fetch own profile');
    const meProfile = await res.json();
    assert(meProfile.role === 'clinic', 'a freshly registered doctor defaults to the clinic role');

    {
      const { DatabaseSync } = require('node:sqlite');
      const { hashPassword } = require('../auth');
      const roleDb = new DatabaseSync(DB_PATH);
      const responderPasswordHash = hashPassword('responder-password-123');
      roleDb.prepare(
        `INSERT INTO doctors (name, license_number, email, password_hash, role)
         VALUES (?, ?, ?, ?, ?)`
      ).run('Test Responder', 'EMS-TEST-001', 'responder@medthru.test', responderPasswordHash, 'responder');
      roleDb.close();

      res = await fetch(`${BASE}/auth/login`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: 'responder@medthru.test', password: 'responder-password-123' }),
      });
      assert(res.status === 200, 'the responder account logs in');
      const responderLogin = await res.json();
      assert(responderLogin.doctor.role === 'responder', 'login response reflects the responder role');
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node test/smoke.js`
Expected: FAIL — either the `INSERT` throws (`table doctors has no column
named role`) if the migration doesn't exist yet, or
`meProfile.role === 'clinic'` fails with `undefined !== 'clinic'` if the
migration exists but `doctorProfile()` doesn't expose it yet. Confirm you
see one of these two failures, not something unrelated — if `medthru.test.db`
already exists from a previous run with an old schema, delete it first
(the test script does this itself on each run, so a plain re-run is fine).

- [ ] **Step 3: Add the migration**

In `db.js`, immediately after the existing clinic_id migration block
(search for `-- Migration: doctor-clinic assignment`), add:

```js
// --- Migration: doctor role (clinic vs. emergency responder) ---
{
  if (!doctorColumns().includes('role')) {
    db.exec(`ALTER TABLE doctors ADD COLUMN role TEXT NOT NULL DEFAULT 'clinic'`);
  }
}
```

- [ ] **Step 4: Expose it on the profile**

In `server.js`, change `doctorProfile()` (around line 198) from:

```js
function doctorProfile(doctor) {
  return {
    id: doctor.id,
    name: doctor.name,
    email: doctor.email,
    phone: doctor.phone,
    license_number: doctor.license_number,
    clinic_id: doctor.clinic_id ?? null,
    created_at: doctor.created_at,
    is_admin: !!doctor.is_admin,
  };
}
```

to:

```js
function doctorProfile(doctor) {
  return {
    id: doctor.id,
    name: doctor.name,
    email: doctor.email,
    phone: doctor.phone,
    license_number: doctor.license_number,
    clinic_id: doctor.clinic_id ?? null,
    created_at: doctor.created_at,
    is_admin: !!doctor.is_admin,
    role: doctor.role,
  };
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `node test/smoke.js`
Expected: PASS on both new assertions (and everything before them, since
this is a single sequential script).

- [ ] **Step 6: Update seed data to set the role explicitly**

In `seed-demo-data.js`, change the shared `insertDoctor` statement (around
line 63) from:

```js
const insertDoctor = db.prepare(
  `INSERT INTO doctors (name, license_number, email, password_hash, phone, is_admin, clinic_id)
   VALUES (?, ?, ?, ?, ?, ?, ?)`
);
```

to:

```js
const insertDoctor = db.prepare(
  `INSERT INTO doctors (name, license_number, email, password_hash, phone, is_admin, clinic_id, role)
   VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
);
```

Then update its two call sites. The clinic-doctor loop (around line 81):

```js
  const result = insertDoctor.run(doc.name, doc.license, doc.email, passwordHash, phone, doc.admin ? 1 : 0, clinicId);
```

becomes:

```js
  const result = insertDoctor.run(doc.name, doc.license, doc.email, passwordHash, phone, doc.admin ? 1 : 0, clinicId, 'clinic');
```

And the EMS loop (around line 93):

```js
  const result = insertDoctor.run(doc.name, doc.license, doc.email, passwordHash, phone, 0, null);
```

becomes:

```js
  const result = insertDoctor.run(doc.name, doc.license, doc.email, passwordHash, phone, 0, null, 'responder');
```

- [ ] **Step 7: Verify seed data still runs cleanly**

Run: `MEDTHRU_DB=/tmp/medthru-seed-check.db node -e "require('./db'); require('./seed-demo-data');"`
(or on Windows PowerShell: `$env:MEDTHRU_DB='seed-check.db'; node -e "require('./db'); require('./seed-demo-data');"`)
Expected: the script completes and prints its usual "Doctors ready: ..."
summary with no errors. Delete the throwaway database file afterward.

- [ ] **Step 8: Commit**

```bash
git add db.js server.js seed-demo-data.js test/smoke.js
git commit -m "Add a role column to doctors, exposed on the profile response"
```

---

### Task 2: `GET /api/doctor/recent-lookups`

**Files:**
- Modify: `server.js` (new route, inserted after `/api/doctor/reports`
  — search for `app.post('/api/appointments/:id/decision'` and insert the
  new route immediately before it)
- Test: `test/smoke.js` (new block, after Task 1's)

**Interfaces:**
- Consumes: `requireDoctor` middleware (already defined in `server.js`,
  attaches `req.doctor`); the existing `audit_log` table and its `'read'`
  action, already written by `GET /api/patients/token/:token` on every
  lookup.
- Produces: `GET /api/doctor/recent-lookups` → `200` with a JSON array of
  `{ patient_id: number, full_name: string, last_viewed: string }`,
  deduplicated to one row per patient, newest `last_viewed` first, capped
  at 20 rows.

- [ ] **Step 1: Write the failing test**

Append to `test/smoke.js`, after Task 1's block and still before the final
`console.log('\nAll smoke checks passed.');`:

```js
    // --- GET /api/doctor/recent-lookups: deduplicated, isolated per doctor ---
    {
      const { DatabaseSync } = require('node:sqlite');
      const { hashPassword } = require('../auth');
      const { generateCardToken, hashCardToken, previewOf } = require('../tokens');

      const fixtureDb = new DatabaseSync(DB_PATH);
      const sharedHash = hashPassword('lookup-test-password');
      const lookupResponderId = Number(fixtureDb.prepare(
        `INSERT INTO doctors (name, license_number, email, password_hash, role) VALUES (?, ?, ?, ?, ?)`
      ).run('Lookup Test Responder', 'EMS-TEST-LOOKUP', 'lookup-responder@medthru.test', sharedHash, 'responder').lastInsertRowid);
      fixtureDb.prepare(
        `INSERT INTO doctors (name, license_number, email, password_hash, role) VALUES (?, ?, ?, ?, ?)`
      ).run('Lookup Test Bystander', 'TEST-BYSTANDER-001', 'bystander@medthru.test', sharedHash, 'clinic');
      const secondPatientId = Number(fixtureDb.prepare(
        `INSERT INTO patients (full_name) VALUES (?)`
      ).run('Second Lookup Patient').lastInsertRowid);
      const secondToken = generateCardToken();
      fixtureDb.prepare(
        `INSERT INTO cards (patient_id, token_hash, preview) VALUES (?, ?, ?)`
      ).run(secondPatientId, hashCardToken(secondToken), previewOf(secondToken));
      fixtureDb.close();
      void lookupResponderId; // inserted for realism; not referenced further

      res = await fetch(`${BASE}/auth/login`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: 'lookup-responder@medthru.test', password: 'lookup-test-password' }),
      });
      assert(res.status === 200, 'the test responder logs in');
      const responderToken = (await res.json()).token;

      // Read the first patient (registered earlier in this file, in scope
      // as `patient`/`cardToken`) twice, and the second patient once.
      await fetch(`${BASE}/patients/token/${cardToken}`, { headers: { Authorization: `Bearer ${responderToken}` } });
      await fetch(`${BASE}/patients/token/${cardToken}`, { headers: { Authorization: `Bearer ${responderToken}` } });
      await fetch(`${BASE}/patients/token/${secondToken}`, { headers: { Authorization: `Bearer ${responderToken}` } });

      res = await fetch(`${BASE}/doctor/recent-lookups`, { headers: { Authorization: `Bearer ${responderToken}` } });
      assert(res.status === 200, 'a responder can fetch their recent lookups');
      const lookups = await res.json();
      assert(lookups.length === 2, 'repeated reads of the same patient collapse to one row');
      const seenIds = lookups.map((l) => l.patient_id);
      assert(seenIds.includes(patient.id), 'the first patient appears exactly once despite two reads');
      assert(seenIds.includes(secondPatientId), 'the second patient appears');

      // Isolation: a doctor who hasn't looked anyone up sees an empty list,
      // not the responder's reads above.
      res = await fetch(`${BASE}/auth/login`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: 'bystander@medthru.test', password: 'lookup-test-password' }),
      });
      const bystanderToken = (await res.json()).token;
      res = await fetch(`${BASE}/doctor/recent-lookups`, { headers: { Authorization: `Bearer ${bystanderToken}` } });
      const bystanderLookups = await res.json();
      assert(bystanderLookups.length === 0, "a doctor who hasn't looked anyone up sees an empty list");
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node test/smoke.js`
Expected: FAIL at `assert(res.status === 200, 'a responder can fetch their
recent lookups')` — the route doesn't exist yet, so Express returns 404.

- [ ] **Step 3: Implement the route**

In `server.js`, immediately before the `/// Confirm, reject, cancel or
complete a booking.` comment and its `app.post('/api/appointments/:id/decision', ...)`
route (search for that comment to find the spot), insert:

```js
/// Patients this doctor has recently looked up (by card tap or otherwise),
/// newest first — reuses the `'read'` rows `GET /api/patients/token/:token`
/// already writes to `audit_log` on every lookup, so no new logging is
/// needed. Grouped by patient: a tap followed by a pull-to-refresh on the
/// same visit must not show that patient twice. Available to any doctor
/// account, not just responders — this is just its first real consumer.
app.get('/api/doctor/recent-lookups', requireDoctor, (req, res) => {
  const rows = db.prepare(`
    SELECT patient_id, patients.full_name,
           MAX(audit_log.timestamp) AS last_viewed
    FROM audit_log
    JOIN patients ON patients.id = audit_log.patient_id
    WHERE audit_log.doctor_id = ? AND audit_log.action = 'read'
    GROUP BY patient_id
    ORDER BY last_viewed DESC
    LIMIT 20
  `).all(req.doctor.id);
  res.json(rows);
});

```

- [ ] **Step 4: Run test to verify it passes**

Run: `node test/smoke.js`
Expected: PASS on every assertion, including the new ones.

- [ ] **Step 5: Commit**

```bash
git add server.js test/smoke.js
git commit -m "Add GET /api/doctor/recent-lookups, deduplicated per patient"
```

---

### Task 3: Client API additions (`doctorRole`, `getRecentLookups`)

**Files:**
- Modify: `app/lib/api.dart:44` (add a getter next to `doctorName`)
- Modify: `app/lib/api.dart:280-286` (add a method next to
  `getDoctorDashboard`)

**Interfaces:**
- Consumes: `GET /api/doctor/recent-lookups` from Task 2 (response shape:
  `[{ patient_id: number, full_name: string, last_viewed: string }]`).
- Produces: `MedThruApi.instance.doctorRole` (`String?`, `'clinic'` |
  `'responder'` | `null` when signed out);
  `MedThruApi.instance.getRecentLookups()` →
  `Future<List<Map<String, dynamic>>>`. Task 5 consumes both.

- [ ] **Step 1: Add the role getter**

In `app/lib/api.dart`, directly after the existing `doctorName` getter:

```dart
  String? get doctorName => _doctor?['name'] as String?;
```

add:

```dart

  /// 'clinic' or 'responder' — null when signed out. Drives which landing
  /// screen `home_screen.dart` shows a signed-in doctor.
  String? get doctorRole => _doctor?['role'] as String?;
```

- [ ] **Step 2: Add the recent-lookups method**

Directly after `getDoctorDashboard()`:

```dart
  Future<Map<String, dynamic>> getDoctorDashboard() async {
    final res = await http.get(Uri.parse('$_baseUrl/doctor/dashboard'), headers: _headers);
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not load the dashboard');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
```

add:

```dart

  /// Patients this doctor has recently looked up, newest first, one row per
  /// patient. Doctor-only — see `GET /api/doctor/recent-lookups`.
  Future<List<Map<String, dynamic>>> getRecentLookups() async {
    final res = await http.get(Uri.parse('$_baseUrl/doctor/recent-lookups'), headers: _headers);
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not load recent lookups');
    }
    return (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
  }
```

- [ ] **Step 3: Verify with static analysis**

Run: `cd app && flutter analyze`
Expected: no new errors or warnings introduced by this change (pre-existing
ones, if any, are out of scope).

- [ ] **Step 4: Commit**

```bash
git add app/lib/api.dart
git commit -m "Add doctorRole getter and getRecentLookups to the API client"
```

---

### Task 4: Branch `home_screen.dart` on responder role

**Files:**
- Modify: `app/lib/screens/home_screen.dart`

**Interfaces:**
- Consumes: `api.doctorRole` (Task 3); `ResponderHomeScreen` (Task 5,
  constructor `ResponderHomeScreen({required String doctorName})`).

- [ ] **Step 1: Import the new screen**

In `app/lib/screens/home_screen.dart`, add to the import block (after the
existing `import 'doctor/reports_screen.dart';`):

```dart
import 'responder/responder_home_screen.dart';
```

- [ ] **Step 2: Compute `isResponder`**

Change:

```dart
    final api = _api;
    final isDoctor = api.isLoggedIn;
```

to:

```dart
    final api = _api;
    final isDoctor = api.isLoggedIn;
    final isResponder = isDoctor && api.doctorRole == 'responder';
```

- [ ] **Step 3: Hide clinic-admin app-bar actions for responders**

Change:

```dart
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
                IconButton(
                  tooltip: 'Reports',
                  icon: const Icon(Icons.insights_outlined),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ReportsScreen()),
                  ),
                ),
                // Account actions tucked into a menu so the bar stays tidy on
                // phones while still exposing the primary nav as icons.
                PopupMenuButton<String>(
```

to:

```dart
            actions: [
              if (isDoctor) ...[
                if (!isResponder) ...[
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
                  IconButton(
                    tooltip: 'Reports',
                    icon: const Icon(Icons.insights_outlined),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const ReportsScreen()),
                    ),
                  ),
                ],
                // Account actions tucked into a menu so the bar stays tidy on
                // phones while still exposing the primary nav as icons.
                PopupMenuButton<String>(
```

(The rest of the `PopupMenuButton` and its closing brackets are unchanged
— only the opening of the `if (isDoctor) ...[` block and the four
`IconButton`s above it move one level deeper, wrapped in `if (!isResponder)
...[`.)

- [ ] **Step 4: Swap the body**

Change:

```dart
          if (isDoctor)
            SliverFillRemaining(
              hasScrollBody: true,
              child: DoctorDashboardScreen(
                doctorName: api.doctorName ?? 'Doctor',
              ),
            )
```

to:

```dart
          if (isDoctor)
            SliverFillRemaining(
              hasScrollBody: true,
              child: isResponder
                  ? ResponderHomeScreen(doctorName: api.doctorName ?? 'Responder')
                  : DoctorDashboardScreen(doctorName: api.doctorName ?? 'Doctor'),
            )
```

- [ ] **Step 5: Verify with static analysis**

Run: `cd app && flutter analyze`
Expected: it will report that `responder/responder_home_screen.dart` (and
the `ResponderHomeScreen` type) don't exist yet — that's expected, since
Task 5 creates them. Confirm there are no *other* new errors in
`home_screen.dart` itself (bracket/paren balance, etc.) beyond that one
missing-import error.

- [ ] **Step 6: Commit**

```bash
git add app/lib/screens/home_screen.dart
git commit -m "Branch the home screen between clinic and responder views"
```

(This commit will not build in isolation — `ResponderHomeScreen` doesn't
exist until Task 5. That's acceptable mid-plan; the plan's final state
builds cleanly. If you'd rather keep every commit independently buildable,
do Task 5 first and this task second instead — there's no dependency
forcing this order.)

---

### Task 5: `ResponderHomeScreen`

**Files:**
- Create: `app/lib/screens/responder/responder_home_screen.dart`

**Interfaces:**
- Consumes: `MedThruApi.instance.getRecentLookups()` (Task 3);
  `PatientSummaryScreen` (existing, `app/lib/screens/doctor/patient_summary_screen.dart`,
  constructor `PatientSummaryScreen({required int patientId, required String patientName})`).
- Produces: `ResponderHomeScreen({required String doctorName})`, consumed by
  `home_screen.dart` (Task 4).

**Design note:** `doctor_dashboard_screen.dart`'s `_Panel`, `_Greeting`,
etc. are private (`_`-prefixed) classes, so they can't be imported from
another file. Rather than refactor that working, unrelated screen to
expose shared public widgets — out of scope for adding one new screen —
this file defines its own small, self-contained private widgets that reuse
the same visual values (corner radius, `surfaceContainerLow`,
`MedThruTheme.softShadow`) by eye, not by sharing code. The hero gradient
uses `MedThruTheme.teal`/`tealDeep` rather than the clinic dashboard's
`coral`/`coralDeep`, so the two roles are visually distinct at a glance.

- [ ] **Step 1: Create the file**

Create `app/lib/screens/responder/responder_home_screen.dart`:

```dart
import 'package:flutter/material.dart';
import '../../api.dart';
import '../../theme.dart';
import '../doctor/patient_summary_screen.dart';

/// The Emergency Response Team's landing screen: a prompt to scan a card,
/// plus a list of patients this responder has recently looked up (for
/// incident recall). Deliberately has none of the clinic dashboard's
/// scheduling/KPI/demographics content — a responder isn't running a
/// practice.
class ResponderHomeScreen extends StatefulWidget {
  const ResponderHomeScreen({super.key, required this.doctorName});
  final String doctorName;

  @override
  State<ResponderHomeScreen> createState() => _ResponderHomeScreenState();
}

class _ResponderHomeScreenState extends State<ResponderHomeScreen> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _future = MedThruApi.instance.getRecentLookups();
    _future.ignore();
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => setState(_load),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _ScanPrompt(name: widget.doctorName),
          const SizedBox(height: 16),
          _RecentLookupsPanel(future: _future),
        ],
      ),
    );
  }
}

class _ScanPrompt extends StatelessWidget {
  const _ScanPrompt({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 26),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [MedThruTheme.teal, MedThruTheme.tealDeep],
        ),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Ready to respond, $name',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Tap a patient's card to pull up their emergency info instantly.",
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9),
              fontSize: 14.5,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentLookupsPanel extends StatelessWidget {
  const _RecentLookupsPanel({required this.future});
  final Future<List<Map<String, dynamic>>> future;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant),
        boxShadow: MedThruTheme.softShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Recently looked up',
            style: TextStyle(
              fontSize: 15.5,
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 14),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snap.hasError) {
                return Text(
                  snap.error.toString().replaceFirst('Exception: ', ''),
                  style: TextStyle(color: scheme.error, fontSize: 13.5),
                );
              }
              final rows = snap.data ?? const [];
              if (rows.isEmpty) {
                return Text(
                  'No patients looked up yet — tap a card to get started.',
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13.5),
                );
              }
              return Column(
                children: [for (final row in rows) _LookupTile(row: row)],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _LookupTile extends StatelessWidget {
  const _LookupTile({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = row['full_name'] as String? ?? 'Patient';
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PatientSummaryScreen(
            patientId: row['patient_id'] as int,
            patientName: name,
          ),
        ),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: MedThruTheme.teal.withValues(alpha: 0.18),
              child: Text(
                name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: const TextStyle(
                  color: MedThruTheme.tealDeep,
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: scheme.onSurface,
                ),
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 18, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Verify with static analysis**

Run: `cd app && flutter analyze`
Expected: no errors in this new file or in `home_screen.dart` (Task 4's
missing-import error from its own Step 5 should now be gone, since the
file and type it referenced now exist).

- [ ] **Step 3: Manual walkthrough**

With the backend running (`node server.js`) and seed data loaded
(`node seed-demo-data.js`), sign into the Flutter app as a seeded responder
account (e.g. `amir.hakim@medthru-ems.test`, password from
`seed-demo-data.js`'s `DEMO_PASSWORD`) — note this requires that
`seed-demo-data.js` has been re-run since Task 1's change, so existing EMS
rows actually have `role = 'responder'` rather than the pre-migration
default of `'clinic'`. Confirm:
- The app-bar no longer shows Register patient / Requests / Patients /
  Reports icons, only the Account menu.
- The landing screen shows the teal "Ready to respond" panel and a
  "Recently looked up" panel (empty state if this account hasn't looked
  anyone up yet).
- Tap a patient's card (or use the `/api/taps` broadcast method already
  established in this project for simulating a tap). Confirm the patient's
  record opens.
- Return to the home screen (back button) and pull to refresh. Confirm the
  just-viewed patient now appears in "Recently looked up," and tapping it
  opens `PatientSummaryScreen` for that patient.
- Sign out and sign in as a seeded clinic doctor (e.g.
  `ahmad.faiz@medthru-clinic.test`). Confirm the clinic dashboard (KPIs,
  schedule, demographics) still appears unchanged, with all four app-bar
  icons present.

- [ ] **Step 4: Commit**

```bash
git add app/lib/screens/responder/responder_home_screen.dart
git commit -m "Add the responder home screen: scan prompt + recent lookups"
```

---

## Plan Self-Review

**Spec coverage:**
- Role storage (`doctors.role`, migration pattern, `doctorProfile()`) →
  Task 1. ✓
- `GET /api/doctor/recent-lookups`, grouped/deduplicated, 20-row cap → Task
  2. ✓
- `api.dart` client additions (`doctorRole`, `getRecentLookups`) → Task 3. ✓
- `home_screen.dart` branching (app-bar actions + body swap) → Task 4. ✓
- `ResponderHomeScreen` (hero + recent-lookups panel, empty state,
  `PatientSummaryScreen` navigation) → Task 5. ✓
- Non-goals (no permission wall, no self-serve signup, no manual
  search) → none of the five tasks add any of these; confirmed by
  inspection. ✓

**Placeholder scan:** no TBD/TODO; every step has concrete code or an exact
command to run.

**Type consistency:** `getRecentLookups()` (Task 3) returns
`Future<List<Map<String, dynamic>>>`, matching what `ResponderHomeScreen`
(Task 5) declares for its `_future` field and `FutureBuilder` type
parameter. `doctorRole` (Task 3) returns `String?`, matching the
`api.doctorRole == 'responder'` comparison in `home_screen.dart` (Task 4).
`ResponderHomeScreen({required String doctorName})` (Task 5) matches the
`ResponderHomeScreen(doctorName: ...)` call site added in Task 4. Server
response field names (`patient_id`, `full_name`, `last_viewed`) match what
`_LookupTile` reads (`row['full_name']`, `row['patient_id']`) — `last_viewed`
is fetched but not currently rendered, which is fine (not every field a
query returns has to be displayed).
