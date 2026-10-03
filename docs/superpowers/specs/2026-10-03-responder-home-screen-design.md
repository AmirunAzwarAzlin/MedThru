# A home screen for Emergency Response Team accounts — design

**Date:** 2026-10-03
**Status:** Approved for planning
**Area:** Backend (`db.js`, `server.js`, `seed-demo-data.js`), Doctor app
(`app/lib/api.dart`, `app/lib/screens/home_screen.dart`, new
`app/lib/screens/responder/responder_home_screen.dart`)

## Background

Emergency Response Team ("EMS") accounts are, today, plain rows in the
`doctors` table — same schema, same login flow, same `requireDoctor`
middleware as a clinic doctor. The only thing distinguishing them is a naming
convention in `seed-demo-data.js` (an `EMS-####` license number and an
`@medthru-ems.test` email). There is no `role` concept anywhere in the
schema or the client.

Because of this, an EMS account signs in and lands on exactly the same
`DoctorDashboardScreen` a clinic doctor sees: today's appointment schedule,
monthly prescription/confirmation KPIs, a patient-age demographics donut, an
appointments-this-month bar chart, and a "new patients" list — plus app-bar
shortcuts to register a patient, review appointment requests, browse the
full patient directory, and view clinic reports. None of this applies to a
responder, who shows up to an incident, taps an unfamiliar patient's card,
and needs their emergency info — not a practice's scheduling metrics.

## Goal

A signed-in Emergency Response Team account sees a landing screen suited to
what they actually do: a prompt to scan a card, and a list of patients
they've recently looked up (for incident recall), with the clinic-admin
app-bar shortcuts (register patient, requests, directory, reports) removed.

## Non-goals

- **No server-side permission wall.** This is a landing-screen and
  navigation-entry-point change, not a security boundary. A responder
  account is not blocked at the API level from clinic-only actions — those
  entry points are simply removed from their UI. (Explicitly raised and
  deferred during design review; can be scoped separately later if wanted.)
- **No change to the contraindication engine, write permissions, or any
  existing screen's logic.** A responder who navigates to a patient's record
  still has the same doctor-level read/write ability a clinic doctor has
  today — this design does not touch that.
- **No self-serve "I'm a responder" signup.** `POST
  /api/auth/register-doctor` keeps defaulting new accounts to `'clinic'`.
  EMS accounts are provisioned directly (seed script or, later, an admin
  action), matching how they're created today.
- **No manual search/lookup fallback on the new screen** — scan-first only,
  per design discussion. Can be added later if a responder without a
  readable card turns out to be a real problem.

## Schema change: `doctors.role`

Follows the existing guarded-migration pattern in `db.js` (same shape as
the `is_admin`/`clinic_id`/`phone` migrations already there):

```js
// --- Migration: doctor role (clinic vs. emergency responder) ---
{
  if (!doctorColumns().includes('role')) {
    db.exec(`ALTER TABLE doctors ADD COLUMN role TEXT NOT NULL DEFAULT 'clinic'`);
  }
}
```

Allowed values: `'clinic'` | `'responder'`. No CHECK constraint is added —
consistent with how `rule_type`, `source`, etc. are handled elsewhere in
this schema (validated in application code, not the database).

`seed-demo-data.js`'s five EMS inserts set `role: 'responder'` explicitly
instead of relying on the `EMS-` license-number prefix as a signal.

## Server changes

### `doctorProfile()` includes `role`

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

So the client knows the role immediately after login/`/api/auth/me`.

### New endpoint: `GET /api/doctor/recent-lookups`

```js
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

Grouped by `patient_id` (not one row per raw read) because
`GET /api/patients/token/:token` already logs a `'read'` audit row on
*every* successful lookup — including pull-to-refresh on an already-open
patient screen — so an ungrouped query would flood the list with repeats of
the same patient. This reuses audit rows that already exist; no new logging
is added anywhere. Available to any doctor account (not gated on role) since
it's a generically useful query — the responder screen is just its first
consumer.

## Client changes

### `api.dart`

```dart
String? get doctorRole => _doctor?['role'] as String?;
```

### `home_screen.dart`

```dart
final isResponder = isDoctor && api.doctorRole == 'responder';
```

- When `isResponder`, the app-bar actions list drops Register patient,
  Requests, Patients, and Reports — keeping only the existing Account
  popup menu (Profile / Settings / Sign out).
- The body swaps between `DoctorDashboardScreen` (clinic) and the new
  `ResponderHomeScreen` (responder), mirroring the existing
  `isDoctor ? ... : ...` branch already in this file.

### New: `app/lib/screens/responder/responder_home_screen.dart`

Same visual language as `DoctorDashboardScreen` (gradient hero panel, the
shared `_Panel` card styling) but with responder-appropriate content:

- **Hero panel**: "Ready to respond" headline; a short line such as "Tap a
  patient's card to pull up their emergency info instantly." No KPI grid,
  schedule, demographics, or appointments chart.
- **"Recently looked up" panel**: fetches `GET
  /api/doctor/recent-lookups`, renders each patient as a tile (name, time
  since last viewed), tapping through to `PatientSummaryScreen` — the same
  read-only view (`cardToken: null`) clinic doctors already get from their
  patient directory, since there's no card in hand after the fact.
- Empty state ("No patients looked up yet — tap a card to get started")
  when the list is empty, matching the empty-state pattern already used
  throughout this app (`CenteredMessage`, `_Panel`'s empty-body text, etc.).

## Testing

- `test/smoke.js`: extend with a case registering a `role: 'responder'`
  doctor (direct DB insert, matching how the test suite seeds other
  fixtures) and asserting `GET /api/doctor/recent-lookups` returns the
  patients that doctor has read, deduplicated, most-recent first — and
  that a second doctor's reads don't leak into the first's list.
- Flutter: no widget-test harness exists for screens in this app
  (established project convention, noted in the bypass-enforcement spec).
  Verify via `flutter analyze` plus a manual walkthrough: sign in as a
  seeded responder account, confirm the app-bar shortcuts are gone, the
  new home screen renders, and tapping a card plus reopening the app
  surfaces that patient in "Recently looked up."

## Known limitations (accepted)

- **No API-level enforcement.** As stated in Non-goals, a responder account
  is not blocked server-side from clinic-only endpoints. This is a UX
  scoping decision, not an oversight — raised explicitly during design and
  deferred as a separate, larger piece of work if ever wanted.
- **`recent-lookups` is doctor-id-scoped only.** If a responder uses
  multiple devices concurrently, "recently looked up" is per-account
  (correct), not per-device — a lookup made on a teammate's phone under a
  shared account would show up for anyone signed into that same account.
  This matches how every other per-doctor view in this app already works
  (e.g. the dashboard's own data is account-scoped, not device-scoped).
