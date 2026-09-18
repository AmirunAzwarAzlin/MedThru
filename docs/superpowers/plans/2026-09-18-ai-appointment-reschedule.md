# AI-Assisted Appointment Reschedule Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a patient or doctor propose moving a confirmed appointment to a new time, with the server ranking realistic alternative slots by a deterministic patient-fit/clinic-fit score and Gemini narrating the top picks.

**Architecture:** A new `reschedule_requested` status sits on top of the existing appointment state machine in `server.js`/`appointments.js`. Candidate slots come from the existing `availableSlots()` machinery, now scoped per-doctor. Scoring lives in a new pure-function module (`reschedule.js`); a second new module (`gemini.js`) wraps the Gemini API call and always degrades to `null` on any failure so the caller falls back to a templated rationale. Flutter gets a new shared `RescheduleScreen` used by both the patient and doctor apps.

**Tech Stack:** Node.js/Express 5, `node:sqlite` (`DatabaseSync`), `@google/genai` (new), `dotenv` (new), Flutter/Dart.

## Global Constraints

- No raw clinical data (reason text, health record contents, patient name) is ever sent to Gemini — only a coarse `urgencyTag` (`routine`/`elevated`/`urgent`) computed server-side.
- `GEMINI_API_KEY` comes from an environment variable only; there is no hardcoded fallback value. A missing key and a failed/timed-out Gemini call take the same fallback path.
- The Gemini call is wrapped in a ~4-second timeout and is never retried.
- Every write (propose, accept, reject) calls the existing `logAudit()` helper, matching the project's "every read and write is audited" invariant.
- Follow the existing code style: no framework in `test/smoke.js` (plain `assert` + `fetch`), plain functions and `db.prepare(...).run/get/all(...)` in the backend, `StatefulWidget` + `MedThruApi.instance` in Flutter screens.
- Design spec: `docs/superpowers/specs/2026-09-18-ai-appointment-reschedule-design.md`.

---

## Task 1: Schema migration — doctor/clinic links, reschedule columns, index fix

**Files:**
- Modify: `db.js` (add `appointmentColumns()` helper near `doctorColumns()`/`patientColumns()` at line ~298; add new migration blocks after the "Migration 1: structured care-plan columns" block, which currently ends at line 358; update the `idx_appointments_slot` index)
- Modify: `appointments.js:11,24-27` (`HELD_STATUSES`, `ALLOWED_TRANSITIONS`)
- Test: `test/smoke.js` (append)

**Interfaces:**
- Produces: `doctors.clinic_id` column, `appointments.doctor_id` / `proposed_starts_at` / `proposed_by` / `reschedule_reason` columns, status `'reschedule_requested'` recognized by `HELD_STATUSES` and `ALLOWED_TRANSITIONS`, and the partial unique index covering it.

- [ ] **Step 1: Add the `appointmentColumns()` helper**

In `db.js`, immediately after the existing `doctorColumns()` function (around line 298):

```js
function appointmentColumns() {
  return db.prepare(`PRAGMA table_info(appointments)`).all().map((c) => c.name);
}
```

- [ ] **Step 2: Add the migration block for `doctors.clinic_id` and the new `appointments` columns**

Immediately after the "Migration 1: structured care-plan columns" block (ends at line 358 today), insert:

```js
// --- Migration: doctor-clinic assignment, for per-doctor scheduling ---
{
  if (!doctorColumns().includes('clinic_id')) {
    db.exec(`ALTER TABLE doctors ADD COLUMN clinic_id INTEGER REFERENCES clinics(id)`);
  }
}

// --- Migration: appointment rescheduling ---
//
// doctor_id is nullable so existing appointments (booked before a doctor was
// picked at booking time) keep working — the reschedule suggestion engine
// falls back to clinic-wide scoring for those. proposed_starts_at/proposed_by/
// reschedule_reason hold a pending reschedule; all three are cleared again
// once it's accepted or rejected. See appointments.js for the accompanying
// HELD_STATUSES/ALLOWED_TRANSITIONS change this depends on.
{
  const cols = appointmentColumns();
  if (!cols.includes('doctor_id')) {
    db.exec(`ALTER TABLE appointments ADD COLUMN doctor_id INTEGER REFERENCES doctors(id)`);
  }
  if (!cols.includes('proposed_starts_at')) {
    db.exec(`ALTER TABLE appointments ADD COLUMN proposed_starts_at TEXT`);
  }
  if (!cols.includes('proposed_by')) {
    db.exec(`ALTER TABLE appointments ADD COLUMN proposed_by TEXT`);
  }
  if (!cols.includes('reschedule_reason')) {
    db.exec(`ALTER TABLE appointments ADD COLUMN reschedule_reason TEXT`);
  }

  // The double-booking guard must both recognize the new status AND stop
  // being clinic-wide now that doctor_id exists. A single
  // (clinic_id, starts_at) index would mean two *different* doctors at the
  // same clinic still couldn't hold appointments at the same wall-clock
  // time — exactly backwards from the point of per-doctor scoping. Split
  // into two partial indexes: legacy doctor-less appointments keep the old
  // clinic-wide guard (there's only one "clinic" pool of capacity for them),
  // while doctor-assigned appointments get their own per-doctor guard.
  // Dropping and recreating the old index is required, not optional —
  // SQLite does not update an existing index's predicate on a second
  // `CREATE ... IF NOT EXISTS` with different WHERE text.
  db.exec(`DROP INDEX IF EXISTS idx_appointments_slot`);
  db.exec(`
    CREATE UNIQUE INDEX IF NOT EXISTS idx_appointments_slot_unassigned
      ON appointments(clinic_id, starts_at)
      WHERE doctor_id IS NULL
        AND status IN ('requested', 'confirmed', 'reschedule_requested')
  `);
  db.exec(`
    CREATE UNIQUE INDEX IF NOT EXISTS idx_appointments_slot_per_doctor
      ON appointments(clinic_id, doctor_id, starts_at)
      WHERE doctor_id IS NOT NULL
        AND status IN ('requested', 'confirmed', 'reschedule_requested')
  `);
}
```

- [ ] **Step 3: Update `appointments.js` constants**

In `appointments.js`, replace:

```js
const HELD_STATUSES = ['requested', 'confirmed'];
```

with:

```js
const HELD_STATUSES = ['requested', 'confirmed', 'reschedule_requested'];
```

And replace:

```js
const ALLOWED_TRANSITIONS = {
  requested: ['confirmed', 'rejected', 'cancelled'],
  confirmed: ['cancelled', 'completed'],
};
```

with:

```js
const ALLOWED_TRANSITIONS = {
  requested: ['confirmed', 'rejected', 'cancelled'],
  confirmed: ['cancelled', 'completed', 'reschedule_requested'],
  reschedule_requested: ['confirmed', 'cancelled'],
};
```

- [ ] **Step 4: Write a smoke test asserting the index and the constants agree**

Place this near the top of `main()`, right after `await waitForServer(proc);`, since it only depends on the server having booted (which runs the migrations) and doesn't depend on any other test state:

```js
    // Verify db.js's migration actually ran: query sqlite_master directly for
    // the index definitions rather than trusting the source file, since this
    // is exactly the kind of drift a normal test wouldn't catch.
    const { DatabaseSync } = require('node:sqlite');
    const probe = new DatabaseSync(DB_PATH);
    const unassignedIdx = probe.prepare(
      `SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'idx_appointments_slot_unassigned'`
    ).get();
    const perDoctorIdx = probe.prepare(
      `SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'idx_appointments_slot_per_doctor'`
    ).get();
    probe.close();
    assert(unassignedIdx && unassignedIdx.sql.includes('reschedule_requested'),
      'idx_appointments_slot_unassigned covers reschedule_requested');
    assert(perDoctorIdx && perDoctorIdx.sql.includes('reschedule_requested') && perDoctorIdx.sql.includes('doctor_id'),
      'idx_appointments_slot_per_doctor covers reschedule_requested and is keyed by doctor_id');
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `npm test`
Expected: all existing assertions still pass, plus `ok - idx_appointments_slot covers reschedule_requested`.

- [ ] **Step 6: Commit**

```bash
git add db.js appointments.js test/smoke.js
git commit -m "Add doctor-clinic and reschedule columns, keep the slot-uniqueness index in sync"
```

---

## Task 2: Doctor-clinic assignment endpoint + clinic doctor listing

**Files:**
- Modify: `server.js` (`doctorProfile()` at line ~192, `PUT /api/auth/me` at line ~208, add `GET /api/clinics/:id/doctors` near the other clinic routes ~line 1173)
- Test: `test/smoke.js` (append)

**Interfaces:**
- Consumes: `activeClinic(id)` (`server.js:1123`, unchanged signature).
- Produces: `GET /api/clinics/:id/doctors` → `[{ id, name, phone }]`. `doctorProfile(doctor)` now includes `clinic_id`.

- [ ] **Step 1: Write the failing test**

Append to `test/smoke.js`, after the doctor registration/login block:

```js
    // A doctor can self-assign to a seeded clinic, and that clinic then
    // lists them.
    res = await fetch(`${BASE}/auth/me`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ clinicId: clinic.id }),
    });
    assert(res.status === 200, 'doctor assigns themself to a clinic');
    const profile = await res.json();
    assert(profile.clinic_id === clinic.id, 'doctor profile reflects the clinic assignment');

    res = await fetch(`${BASE}/clinics/${clinic.id}/doctors`);
    const clinicDoctors = await res.json();
    assert(clinicDoctors.some((d) => d.name === 'CI Doctor'),
      'the clinic lists its assigned doctor');
    assert(!('email' in clinicDoctors[0]) && !('license_number' in clinicDoctors[0]),
      'the clinic doctor listing does not leak private fields');
```

This references `clinic`, which is defined further down in the existing file (the "pick a clinic open every day" block). Move that clinic-selection block (the four lines starting `res = await fetch(\`${BASE}/clinics\`);` through `assert(clinic, ...)`) to *before* this new snippet, immediately after the doctor login block, since both the reschedule tests in later tasks and this one need `clinic` in scope early. Cut the block from its current location and paste it right after the `register-doctor` / admin-gating assertions, before the "Patient registration" section.

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test`
Expected: FAIL — `/api/clinics/:id/doctors` is `404` (route doesn't exist) or `PUT /api/auth/me` doesn't accept `clinicId` yet (profile.clinic_id is `undefined`).

- [ ] **Step 3: Implement**

In `server.js`, update `doctorProfile()` (currently at line ~192-201):

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
```
(leave the rest of the function body as-is).

Update `PUT /api/auth/me` (currently at line ~208-232):

```js
app.put('/api/auth/me', requireDoctor, (req, res) => {
  const { name, email, phone, clinicId } = req.body;
  const updates = [];
  const values = [];
  if (name !== undefined) { updates.push('name = ?'); values.push(name); }
  if (email !== undefined) { updates.push('email = ?'); values.push(email); }
  if (phone !== undefined) { updates.push('phone = ?'); values.push(phone || null); }
  if (clinicId !== undefined) {
    if (clinicId === null) {
      updates.push('clinic_id = ?');
      values.push(null);
    } else {
      const clinic = activeClinic(clinicId);
      if (!clinic) return res.status(404).json({ error: 'Clinic not found' });
      updates.push('clinic_id = ?');
      values.push(clinic.id);
    }
  }

  if (updates.length === 0) {
    return res.json(doctorProfile(req.doctor));
  }

  try {
    values.push(req.doctor.id);
    db.prepare(`UPDATE doctors SET ${updates.join(', ')} WHERE id = ?`).run(...values);
  } catch (err) {
    if (String(err.message).includes('UNIQUE')) {
      return res.status(409).json({ error: 'That email is already in use.' });
    }
    throw err;
  }

  const updated = db.prepare(`SELECT * FROM doctors WHERE id = ?`).get(req.doctor.id);
  res.json(doctorProfile(updated));
});
```

`activeClinic` is defined later in the file (`server.js:1123`), but as a `function` declaration it's hoisted, so this is safe to call here.

Add a new route right after `app.get('/api/clinics', ...)` (currently ending at line ~1173):

```js
/// Doctors assigned to a clinic, for the patient booking flow's doctor-picker
/// step. Deliberately narrow — no email or license number, which are private.
app.get('/api/clinics/:id/doctors', (req, res) => {
  const clinic = activeClinic(req.params.id);
  if (!clinic) {
    return res.status(404).json({ error: 'Clinic not found' });
  }
  res.json(db.prepare(
    `SELECT id, name, phone FROM doctors WHERE clinic_id = ? ORDER BY name`
  ).all(clinic.id));
});
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test`
Expected: PASS for all three new assertions.

- [ ] **Step 5: Commit**

```bash
git add server.js test/smoke.js
git commit -m "Add doctor-clinic self-assignment and the clinic doctor listing"
```

---

## Task 3: Per-doctor availability and booking

**Files:**
- Modify: `server.js` (`heldTimes()` ~line 1158, `GET /api/clinics/:id/availability` ~line 1209, `POST /api/patients/token/:token/appointments` ~line 1227, `APPOINTMENT_SELECT` ~line 1105)
- Test: `test/smoke.js` (append)

**Interfaces:**
- Consumes: `HELD_STATUSES`, `HELD_PLACEHOLDERS` (`server.js:1103`).
- Produces: `heldTimes(clinicId, dateStr, doctorId?)`; `appointments.doctor_id` populated on booking; `APPOINTMENT_SELECT` rows now carry `doctor_name`.

- [ ] **Step 1: Write the failing test**

Append to `test/smoke.js`, after the clinic-doctor-listing assertions from Task 2:

```js
    // Two doctors at the same clinic must not block each other's slots, and
    // booking against one doctor should not show up as held time for the
    // other.
    res = await fetch(`${BASE}/auth/register-doctor`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        name: 'Second CI Doctor',
        licenseNumber: 'CI-002',
        email: 'ci2@medthru.test',
        password: 'ci-password-123',
      }),
    });
    const { token: token2 } = await res.json();
    await fetch(`${BASE}/auth/me`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token2}` },
      body: JSON.stringify({ clinicId: clinic.id }),
    });
    res = await fetch(`${BASE}/clinics/${clinic.id}/doctors`);
    const twoDoctors = await res.json();
    const doctorA = twoDoctors.find((d) => d.name === 'CI Doctor');
    const doctorB = twoDoctors.find((d) => d.name === 'Second CI Doctor');

    res = await fetch(`${BASE}/clinics/${clinic.id}/availability?date=${aWeekOut}&doctorId=${doctorA.id}`);
    const { slots: doctorASlots } = await res.json();
    const pickedSlot = doctorASlots[0];

    res = await fetch(`${BASE}/patients/token/${cardToken}/appointments`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        clinicId: clinic.id, doctorId: doctorA.id,
        startsAt: `${aWeekOut} ${pickedSlot}`, reason: 'Doctor-scoped booking test',
      }),
    });
    assert(res.status === 201, 'book against a specific doctor at the clinic');
    const doctorABooking = await res.json();
    assert(doctorABooking.doctor_id === doctorA.id, 'the booking records the chosen doctor');
    assert(doctorABooking.doctor_name === 'CI Doctor', 'the booking response includes the doctor name');

    res = await fetch(`${BASE}/clinics/${clinic.id}/availability?date=${aWeekOut}&doctorId=${doctorB.id}`);
    const { slots: doctorBSlots } = await res.json();
    assert(doctorBSlots.includes(pickedSlot),
      "doctor B's availability is unaffected by doctor A's booking");

    res = await fetch(`${BASE}/clinics/${clinic.id}/availability?date=${aWeekOut}&doctorId=${doctorA.id}`);
    const { slots: doctorASlotsAfter } = await res.json();
    assert(!doctorASlotsAfter.includes(pickedSlot),
      "doctor A's own availability no longer offers the booked slot");

    // The real regression test: doctor B must be able to actually book the
    // exact same wall-clock slot doctor A just took. A clinic-wide unique
    // index (rather than one scoped by doctor) would make this 409 even
    // though it should succeed — two different doctors, two different rooms.
    res = await fetch(`${BASE}/patients/token/${cardToken}/appointments`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        clinicId: clinic.id, doctorId: doctorB.id,
        startsAt: `${aWeekOut} ${pickedSlot}`, reason: 'Concurrent booking with a different doctor',
      }),
    });
    assert(res.status === 201,
      'doctor B can book the identical time slot doctor A already holds');
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test`
Expected: FAIL — availability ignores `doctorId` (so `doctorBSlots` incorrectly excludes `pickedSlot`), the booking response has no `doctor_id`/`doctor_name`, and doctor B's booking against `pickedSlot` 409s because the unique index is still clinic-wide.

- [ ] **Step 3: Implement**

In `server.js`, update `heldTimes()` (currently at line ~1158-1165):

```js
/// The "HH:MM" times already held by live appointments at a clinic on a
/// date. Scoped to one doctor's day when `doctorId` is given, so two doctors
/// at the same clinic don't block each other's slots.
function heldTimes(clinicId, dateStr, doctorId) {
  const doctorClause = doctorId ? ' AND doctor_id = ?' : '';
  const params = [clinicId, `${dateStr}%`, ...HELD_STATUSES];
  if (doctorId) params.push(doctorId);
  return db.prepare(
    `SELECT starts_at FROM appointments
     WHERE clinic_id = ? AND starts_at LIKE ? AND status IN (${HELD_PLACEHOLDERS})${doctorClause}`
  )
    .all(...params)
    .map((row) => row.starts_at.slice(11, 16));
}
```

Update `GET /api/clinics/:id/availability` (currently at line ~1209-1225):

```js
app.get('/api/clinics/:id/availability', (req, res) => {
  const clinic = activeClinic(req.params.id);
  if (!clinic) {
    return res.status(404).json({ error: 'Clinic not found' });
  }

  const date = req.query.date ?? toDateString(new Date());
  if (!isValidDate(date)) {
    return res.status(400).json({ error: 'date must look like "YYYY-MM-DD"' });
  }

  const doctorId = req.query.doctorId ? Number(req.query.doctorId) : undefined;
  res.json({
    clinic,
    date,
    slots: availableSlots(clinic, date, heldTimes(clinic.id, date, doctorId)),
  });
});
```

Update `APPOINTMENT_SELECT` (currently at line ~1105-1117) to join the assigned doctor as well as the deciding one:

```js
const APPOINTMENT_SELECT = `
  SELECT appointments.*,
         clinics.name    AS clinic_name,
         clinics.kind    AS clinic_kind,
         clinics.address AS clinic_address,
         clinics.phone   AS clinic_phone,
         patients.full_name   AS patient_name,
         assigned_doctor.name AS doctor_name,
         decided_doctor.name  AS decided_by_name
  FROM appointments
  JOIN clinics  ON clinics.id  = appointments.clinic_id
  JOIN patients ON patients.id = appointments.patient_id
  LEFT JOIN doctors AS assigned_doctor ON assigned_doctor.id = appointments.doctor_id
  LEFT JOIN doctors AS decided_doctor  ON decided_doctor.id  = appointments.decided_by
`;
```

Update `POST /api/patients/token/:token/appointments` (currently at line ~1227-1273):

```js
app.post('/api/patients/token/:token/appointments', lookupLimiter, (req, res) => {
  const patient = resolvePatientFromReq(req);
  if (!patient) {
    return res.status(404).json({ error: 'No patient found for this card' });
  }

  const clinic = activeClinic(req.body.clinicId);
  if (!clinic) {
    return res.status(404).json({ error: 'Clinic not found' });
  }

  let doctorId = null;
  if (req.body.doctorId !== undefined && req.body.doctorId !== null) {
    const doctor = db.prepare(`SELECT id FROM doctors WHERE id = ? AND clinic_id = ?`)
      .get(Number(req.body.doctorId), clinic.id);
    if (!doctor) {
      return res.status(400).json({ error: 'doctorId must be a doctor at this clinic' });
    }
    doctorId = doctor.id;
  }

  const startsAt = normalizeStartsAt(req.body.startsAt);
  const problem = bookingError(clinic, startsAt);
  if (problem) {
    return res.status(400).json({ error: problem });
  }

  let result;
  try {
    result = db.prepare(
      `INSERT INTO appointments (patient_id, clinic_id, doctor_id, starts_at, slot_minutes, reason)
       VALUES (?, ?, ?, ?, ?, ?)`
    ).run(
      patient.id,
      clinic.id,
      doctorId,
      startsAt,
      clinic.slot_minutes,
      optionalText(req.body.reason),
    );
  } catch (err) {
    if (String(err.message).includes('UNIQUE')) {
      return res.status(409).json({
        error: 'That slot has just been taken. Please choose another time.',
      });
    }
    throw err;
  }

  const doctor = doctorFromRequest(req);
  logAudit(patient.id, doctor ? doctor.id : null, 'appointment_request',
    `Requested ${startsAt} at ${clinic.name}`);

  res.status(201).json(appointmentById(Number(result.lastInsertRowid)));
});
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test`
Expected: PASS for all assertions in this task.

- [ ] **Step 5: Commit**

```bash
git add server.js test/smoke.js
git commit -m "Scope appointment availability and booking per doctor"
```

---

## Task 4: Reschedule scoring module (`reschedule.js`)

**Files:**
- Create: `reschedule.js`
- Test: `test/reschedule-scoring.js` (new)
- Modify: `package.json` (`scripts.test`)

**Interfaces:**
- Produces: `urgencyTag(reason, hasChronicCondition)`, `patientFit({ originalStartsAt, candidateStartsAt, tag, now })`, `clinicFit({ candidateStartsAt, sameDayBookedTimes, slotMinutes, typicalDailyLoad })`, `rankCandidates({ originalStartsAt, candidates, tag, sameDayBookedTimesByDate, slotMinutes, typicalDailyLoad, now, limit })` → `[{ startsAt, patientFit, clinicFit, total }]` sorted best-first.

This module is pure functions only — no `db`, no network — so it's tested directly with plain `assert`, no spawned server needed.

- [ ] **Step 1: Write the failing test**

Create `test/reschedule-scoring.js`:

```js
// Unit tests for the pure scoring functions behind AI-assisted reschedule
// suggestions. No server, no database — these are plain functions.
'use strict';

const assert = require('node:assert');
const { urgencyTag, patientFit, clinicFit, rankCandidates } = require('../reschedule');

function check(condition, message) {
  assert.ok(condition, message);
  console.log(`ok - ${message}`);
}

// --- urgencyTag ---
check(urgencyTag('Severe allergic reaction', false) === 'urgent',
  'a "severe" reason is tagged urgent');
check(urgencyTag('Routine checkup', false) === 'routine',
  'a plain checkup is tagged routine');
check(urgencyTag('Routine checkup', true) === 'elevated',
  'a chronic condition bumps an otherwise-routine reason to elevated');
check(urgencyTag(null, false) === 'routine',
  'a missing reason defaults to routine, not a crash');

// --- patientFit ---
const now = new Date('2026-09-18T00:00:00');
const sameTimeNextWeek = patientFit({
  originalStartsAt: '2026-09-18 10:00',
  candidateStartsAt: '2026-09-25 10:00',
  tag: 'routine',
  now,
});
const differentTimeNextWeek = patientFit({
  originalStartsAt: '2026-09-18 10:00',
  candidateStartsAt: '2026-09-25 16:00',
  tag: 'routine',
  now,
});
check(sameTimeNextWeek > differentTimeNextWeek,
  'a candidate at the same time-of-day scores higher than one at a different time');

const urgentCase = patientFit({
  originalStartsAt: '2026-09-18 10:00',
  candidateStartsAt: '2026-09-25 10:00',
  tag: 'urgent',
  now,
});
check(urgentCase > sameTimeNextWeek,
  'an urgent tag scores the same slot higher than a routine one');

// --- clinicFit ---
const fillsGap = clinicFit({
  candidateStartsAt: '2026-09-25 10:30',
  sameDayBookedTimes: ['10:00', '11:00'],
  slotMinutes: 30,
  typicalDailyLoad: 0,
});
const fragmentsDay = clinicFit({
  candidateStartsAt: '2026-09-25 15:00',
  sameDayBookedTimes: ['10:00', '11:00'],
  slotMinutes: 30,
  typicalDailyLoad: 0,
});
check(fillsGap > fragmentsDay,
  'a slot adjacent to an existing booking scores higher than an isolated one');

const overloadedDay = clinicFit({
  candidateStartsAt: '2026-09-25 15:00',
  sameDayBookedTimes: ['09:00', '10:00', '11:00', '13:00', '14:00'],
  slotMinutes: 30,
  typicalDailyLoad: 3,
});
check(overloadedDay < fragmentsDay,
  'piling onto a day already above its typical load scores lower');

// --- rankCandidates ---
const ranked = rankCandidates({
  originalStartsAt: '2026-09-18 10:00',
  candidates: ['2026-09-25 10:00', '2026-09-25 15:00', '2026-10-02 10:00'],
  tag: 'routine',
  sameDayBookedTimesByDate: { '2026-09-25': ['10:30'], '2026-10-02': [] },
  slotMinutes: 30,
  typicalDailyLoad: 0,
  now,
  limit: 5,
});
check(ranked.length === 3, 'rankCandidates returns every candidate when under the limit');
check(ranked[0].startsAt === '2026-09-25 10:00',
  'the closest-time, soonest, gap-adjacent candidate ranks first');
check(ranked.every((r) => typeof r.total === 'number'), 'every ranked candidate carries a total score');
check(ranked[0].total >= ranked[1].total && ranked[1].total >= ranked[2].total,
  'results are sorted best-first');

const limited = rankCandidates({
  originalStartsAt: '2026-09-18 10:00',
  candidates: ['2026-09-25 10:00', '2026-09-25 15:00', '2026-10-02 10:00'],
  tag: 'routine',
  sameDayBookedTimesByDate: {},
  slotMinutes: 30,
  typicalDailyLoad: 0,
  now,
  limit: 2,
});
check(limited.length === 2, 'rankCandidates respects the limit');

console.log('All reschedule-scoring tests passed.');
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node test/reschedule-scoring.js`
Expected: FAIL with `Cannot find module '../reschedule'`.

- [ ] **Step 3: Implement `reschedule.js`**

Create `reschedule.js`:

```js
/// Deterministic scoring for AI-assisted appointment rescheduling.
///
/// Two independent 0-100 scores per candidate slot: how well it fits the
/// patient (closeness to their original time, urgency) and how well it fits
/// the doctor's day (fills a gap rather than fragmenting it, keeps the day's
/// load near what's typical). The two combine into one ranking; nothing here
/// talks to Gemini or the database — see `gemini.js` and `server.js`.

const URGENCY_KEYWORDS = {
  urgent: ['urgent', 'severe', 'emergency', 'acute'],
  elevated: ['follow-up', 'follow up', 'pain', 'worsening', 'chronic'],
};

/// A coarse, non-clinical urgency tag from free text plus whether the patient
/// has a chronic condition on file. This tag — never the raw reason text —
/// is the only signal that reaches Gemini.
function urgencyTag(reason, hasChronicCondition) {
  const text = String(reason ?? '').toLowerCase();
  if (URGENCY_KEYWORDS.urgent.some((k) => text.includes(k))) return 'urgent';
  if (hasChronicCondition || URGENCY_KEYWORDS.elevated.some((k) => text.includes(k))) {
    return 'elevated';
  }
  return 'routine';
}

const URGENCY_WEIGHT = { routine: 0, elevated: 15, urgent: 30 };

function minutesOfDay(hhmm) {
  const [h, m] = hhmm.split(':').map(Number);
  return h * 60 + m;
}

/// How well `candidateStartsAt` ("YYYY-MM-DD HH:MM") fits the patient, 0-100
/// (higher is better): closer to the original slot's time-of-day, sooner,
/// and bumped for elevated/urgent cases.
function patientFit({ originalStartsAt, candidateStartsAt, tag, now = new Date() }) {
  const [, origTime] = originalStartsAt.split(' ');
  const [candDate, candTime] = candidateStartsAt.split(' ');

  const timeDelta = Math.abs(minutesOfDay(candTime) - minutesOfDay(origTime));
  const timeScore = Math.max(0, 40 - timeDelta / 6); // same time -> 40, 4h+ apart -> 0

  const daysOut = Math.max(0, (new Date(`${candDate}T${candTime}:00`) - now) / 86_400_000);
  const soonScore = Math.max(0, 30 - daysOut * 2); // today -> 30, 15+ days out -> 0

  return Math.min(100, timeScore + soonScore + URGENCY_WEIGHT[tag]);
}

/// How well `candidateStartsAt` fits the doctor's day, 0-100 (higher is
/// better): rewards a slot immediately adjacent to an existing booking that
/// day over one sitting alone, and penalizes a day already above its
/// typical load (0 disables the penalty — used when there isn't enough
/// history for a doctor yet).
function clinicFit({ candidateStartsAt, sameDayBookedTimes, slotMinutes, typicalDailyLoad }) {
  const [, candTime] = candidateStartsAt.split(' ');
  const candMin = minutesOfDay(candTime);

  const gapBonus = sameDayBookedTimes.some(
    (t) => Math.abs(minutesOfDay(t) - candMin) === slotMinutes
  ) ? 40 : 0;

  const projectedLoad = sameDayBookedTimes.length + 1;
  const loadPenalty = typicalDailyLoad > 0
    ? Math.max(0, (projectedLoad - typicalDailyLoad) * 10)
    : 0;

  return Math.max(0, Math.min(100, 60 + gapBonus - loadPenalty));
}

const PATIENT_WEIGHT = 0.6;
const CLINIC_WEIGHT = 0.4;

/// Ranks `candidates` (array of "YYYY-MM-DD HH:MM" strings) best-first,
/// returning at most `limit` with their score breakdown.
function rankCandidates({
  originalStartsAt, candidates, tag, sameDayBookedTimesByDate,
  slotMinutes, typicalDailyLoad, now, limit = 5,
}) {
  const scored = candidates.map((candidateStartsAt) => {
    const [candDate] = candidateStartsAt.split(' ');
    const pFit = patientFit({ originalStartsAt, candidateStartsAt, tag, now });
    const cFit = clinicFit({
      candidateStartsAt,
      sameDayBookedTimes: sameDayBookedTimesByDate[candDate] ?? [],
      slotMinutes,
      typicalDailyLoad,
    });
    return {
      startsAt: candidateStartsAt,
      patientFit: pFit,
      clinicFit: cFit,
      total: PATIENT_WEIGHT * pFit + CLINIC_WEIGHT * cFit,
    };
  });
  scored.sort((a, b) => b.total - a.total);
  return scored.slice(0, limit);
}

module.exports = { urgencyTag, patientFit, clinicFit, rankCandidates };
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node test/reschedule-scoring.js`
Expected: PASS, ending with `All reschedule-scoring tests passed.`

- [ ] **Step 5: Wire it into `npm test`**

In `package.json`, change:

```json
"test": "node test/smoke.js",
```

to:

```json
"test": "node test/reschedule-scoring.js && node test/smoke.js",
```

- [ ] **Step 6: Run `npm test` to verify both suites pass**

Run: `npm test`
Expected: PASS (reschedule-scoring output, then smoke.js output).

- [ ] **Step 7: Commit**

```bash
git add reschedule.js test/reschedule-scoring.js package.json
git commit -m "Add deterministic patient-fit/clinic-fit scoring for reschedule suggestions"
```

---

## Task 5: Gemini integration module (`gemini.js`)

**Files:**
- Create: `gemini.js`
- Test: `test/gemini.js` (new)
- Modify: `package.json` (`dependencies`, `scripts.test`)
- Create: `.env.example`

**Interfaces:**
- Consumes: candidates in the shape `rankCandidates()` produces (`{ startsAt, patientFit, clinicFit, total }`).
- Produces: `rationalizeCandidates({ originalStartsAt, urgencyTag, candidates }, { genAI, timeoutMs })` → `Promise<[{ startsAt, rationale }] | null>`. `null` on missing key, any thrown error, timeout, or a malformed response — never throws.

- [ ] **Step 1: Add dependencies**

Run:

```bash
npm install @google/genai dotenv
```

Verify `package.json`'s `dependencies` now lists both.

- [ ] **Step 2: Write `.env.example`**

Create `.env.example`:

```
# Copy to .env and fill in for local development. .env is gitignored.
GEMINI_API_KEY=
```

- [ ] **Step 3: Write the failing test**

Create `test/gemini.js`:

```js
// Unit tests for the Gemini wrapper. No real network call — a fake client is
// injected so these run offline and fast. The one thing worth proving here
// is that this module never throws: missing key, thrown error, timeout, and
// a malformed response all resolve to `null`.
'use strict';

const assert = require('node:assert');
const { rationalizeCandidates } = require('../gemini');

function check(condition, message) {
  assert.ok(condition, message);
  console.log(`ok - ${message}`);
}

const candidates = [
  { startsAt: '2026-09-25 10:00', patientFit: 80, clinicFit: 70, total: 76 },
];

async function main() {
  // No genAI client injected and no GEMINI_API_KEY in this test process's
  // environment (test/smoke.js doesn't set one) — the default client resolves
  // to null, so this must resolve to null without attempting a network call.
  delete process.env.GEMINI_API_KEY;
  const noKey = await rationalizeCandidates(
    { originalStartsAt: '2026-09-18 10:00', urgencyTag: 'routine', candidates }
  );
  check(noKey === null, 'no API key -> null, no network attempt');

  // A fake client that resolves with well-formed JSON.
  const goodClient = {
    models: {
      generateContent: async () => ({
        text: JSON.stringify({
          suggestions: [{ startsAt: '2026-09-25 10:00', rationale: 'Keeps your usual morning slot.' }],
        }),
      }),
    },
  };
  const good = await rationalizeCandidates(
    { originalStartsAt: '2026-09-18 10:00', urgencyTag: 'routine', candidates },
    { genAI: goodClient },
  );
  check(Array.isArray(good) && good.length === 1 && good[0].rationale.length > 0,
    'a well-formed response is returned as-is');

  // A fake client that throws.
  const throwingClient = {
    models: { generateContent: async () => { throw new Error('network down'); } },
  };
  const thrown = await rationalizeCandidates(
    { originalStartsAt: '2026-09-18 10:00', urgencyTag: 'routine', candidates },
    { genAI: throwingClient },
  );
  check(thrown === null, 'a thrown error resolves to null, not a rejected promise');

  // A fake client that never resolves — must hit the timeout, not hang.
  const hangingClient = {
    models: { generateContent: () => new Promise(() => {}) },
  };
  const start = Date.now();
  const timedOut = await rationalizeCandidates(
    { originalStartsAt: '2026-09-18 10:00', urgencyTag: 'routine', candidates },
    { genAI: hangingClient, timeoutMs: 200 },
  );
  check(timedOut === null, 'a hanging call times out to null');
  check(Date.now() - start < 1000, 'the timeout fires close to the configured delay, not the default');

  // A fake client that resolves with malformed JSON.
  const malformedClient = {
    models: { generateContent: async () => ({ text: '{"not": "the expected shape"}' }) },
  };
  const malformed = await rationalizeCandidates(
    { originalStartsAt: '2026-09-18 10:00', urgencyTag: 'routine', candidates },
    { genAI: malformedClient },
  );
  check(malformed === null, 'a malformed response resolves to null');

  console.log('All gemini tests passed.');
}

main();
```

- [ ] **Step 4: Run test to verify it fails**

Run: `node test/gemini.js`
Expected: FAIL with `Cannot find module '../gemini'`.

- [ ] **Step 5: Implement `gemini.js`**

Create `gemini.js`:

```js
/// Thin wrapper around the Gemini API for turning an already-ranked list of
/// reschedule candidates (see `reschedule.js`) into a short rationale per
/// option. The ranking never comes from here — this module only captions the
/// top picks, and degrades to `null` (never throws) on any failure, so the
/// caller always has a templated fallback to use instead.
const { GoogleGenAI } = require('@google/genai');

const MODEL = 'gemini-2.5-flash';
const DEFAULT_TIMEOUT_MS = 4000;

let cachedClient = null;
function defaultClient() {
  if (!process.env.GEMINI_API_KEY) return null;
  if (!cachedClient) {
    cachedClient = new GoogleGenAI({ apiKey: process.env.GEMINI_API_KEY });
  }
  return cachedClient;
}

const RESPONSE_SCHEMA = {
  type: 'object',
  properties: {
    suggestions: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          startsAt: { type: 'string' },
          rationale: { type: 'string' },
        },
        required: ['startsAt', 'rationale'],
      },
    },
  },
  required: ['suggestions'],
};

function buildPrompt({ originalStartsAt, urgencyTag, candidates }) {
  const lines = candidates.map((c) =>
    `- ${c.startsAt} (patientFit=${c.patientFit.toFixed(0)}, clinicFit=${c.clinicFit.toFixed(0)})`
  );
  return [
    `A patient's appointment originally at ${originalStartsAt} needs to move. Urgency: ${urgencyTag}.`,
    'Candidate slots, best first, with fit scores 0-100 (higher is better):',
    ...lines,
    'For each candidate, in the same order, write one short (under 20 words) ' +
      'rationale a patient would find reassuring, referencing only the day/time ' +
      'and urgency given above. Do not invent medical details.',
  ].join('\n');
}

/// Returns `[{ startsAt, rationale }]` in the same order as `candidates`, or
/// `null` if Gemini is unconfigured, unreachable, too slow, or responds with
/// something that doesn't parse. `genAI`/`timeoutMs` are injectable for
/// testing without a real API key or a real 4-second wait.
async function rationalizeCandidates(
  { originalStartsAt, urgencyTag, candidates },
  { genAI = defaultClient(), timeoutMs = DEFAULT_TIMEOUT_MS } = {},
) {
  if (!genAI || candidates.length === 0) return null;

  try {
    const response = await Promise.race([
      genAI.models.generateContent({
        model: MODEL,
        contents: buildPrompt({ originalStartsAt, urgencyTag, candidates }),
        config: {
          responseMimeType: 'application/json',
          responseSchema: RESPONSE_SCHEMA,
        },
      }),
      new Promise((_, reject) =>
        setTimeout(() => reject(new Error('Gemini timeout')), timeoutMs)
      ),
    ]);

    const parsed = JSON.parse(response.text);
    if (!Array.isArray(parsed.suggestions) || parsed.suggestions.length === 0) {
      return null;
    }
    return parsed.suggestions;
  } catch {
    return null;
  }
}

module.exports = { rationalizeCandidates, buildPrompt };
```

- [ ] **Step 6: Run test to verify it passes**

Run: `node test/gemini.js`
Expected: PASS, ending with `All gemini tests passed.`

- [ ] **Step 7: Wire it into `npm test` and load `.env` at server startup**

In `package.json`, change:

```json
"test": "node test/reschedule-scoring.js && node test/smoke.js",
```

to:

```json
"test": "node test/reschedule-scoring.js && node test/gemini.js && node test/smoke.js",
```

In `server.js`, add as the very first line (before `const express = require('express');`):

```js
require('dotenv').config();
```

- [ ] **Step 8: Run `npm test` to verify all three suites pass**

Run: `npm test`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add gemini.js test/gemini.js package.json package-lock.json server.js .env.example
git commit -m "Add the Gemini rationale wrapper, always degrading to null on failure"
```

---

## Task 6: Reschedule propose/respond endpoints

**Files:**
- Modify: `server.js` (add near the existing appointment endpoints, after `POST /api/appointments/:id/decision` at line ~1566)
- Test: `test/smoke.js` (append)

**Interfaces:**
- Consumes: `ALLOWED_TRANSITIONS`, `HELD_STATUSES` (`appointments.js`, updated in Task 1); `appointmentById`, `logAudit`, `resolvePatientFromReq`, `activeClinic`, `bookingError`, `normalizeStartsAt`, `optionalText` (all existing).
- Produces: the six endpoints from the spec's API surface table; a shared `respondToReschedule(appointment, accept, doctorId, patientId)` helper returning `null` on success or `{ status, error }` on a slot conflict.

- [ ] **Step 1: Write the failing test**

Append to `test/smoke.js`, after the Task 3 doctor-scoping assertions:

```js
    // Reschedule: patient proposes, doctor accepts.
    res = await fetch(`${BASE}/patients/token/${cardToken}/appointments`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        clinicId: clinic.id, doctorId: doctorA.id,
        startsAt: `${aWeekOut} ${doctorASlotsAfter[0]}`, reason: 'Reschedule flow test',
      }),
    });
    const rescheduleTarget = await res.json();
    await fetch(`${BASE}/appointments/${rescheduleTarget.id}/decision`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ status: 'confirmed' }),
    });

    res = await fetch(`${BASE}/clinics/${clinic.id}/availability?date=${aWeekOut}&doctorId=${doctorA.id}`);
    const { slots: freshSlots } = await res.json();
    const newTime = freshSlots[0];

    res = await fetch(`${BASE}/patients/token/${cardToken}/appointments/${rescheduleTarget.id}/reschedule`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ startsAt: `${aWeekOut} ${newTime}` }),
    });
    assert(res.status === 200, 'patient proposes a reschedule');
    let updated = await res.json();
    assert(updated.status === 'reschedule_requested', 'status moves to reschedule_requested');
    assert(updated.proposed_by === 'patient', 'proposed_by records the patient');

    // The original slot must still be held: a second patient cannot book it.
    res = await fetch(`${BASE}/patients`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ full_name: 'Second CI Patient' }),
    });
    const { cardToken: cardToken2 } = await res.json();
    res = await fetch(`${BASE}/patients/token/${cardToken2}/appointments`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        clinicId: clinic.id, doctorId: doctorA.id,
        startsAt: rescheduleTarget.starts_at, reason: 'Should be blocked',
      }),
    });
    assert(res.status === 409, "a reschedule_requested appointment's original slot stays held");

    res = await fetch(`${BASE}/appointments/${rescheduleTarget.id}/reschedule/respond`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ accept: true }),
    });
    assert(res.status === 200, 'doctor accepts the patient-proposed reschedule');
    updated = await res.json();
    assert(updated.status === 'confirmed', 'accepted reschedule returns to confirmed');
    assert(updated.starts_at === `${aWeekOut} ${newTime}`, 'starts_at moved to the proposed time');
    assert(updated.proposed_starts_at === null, 'proposed_starts_at is cleared after accept');

    // Reschedule: doctor proposes, patient rejects -> original time stays.
    res = await fetch(`${BASE}/appointments/${rescheduleTarget.id}/reschedule`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ startsAt: `${aWeekOut} ${freshSlots[1] ?? freshSlots[0]}` }),
    });
    assert(res.status === 200, 'doctor proposes a reschedule');
    const beforeReject = await res.json();
    assert(beforeReject.proposed_by === 'doctor', 'proposed_by records the doctor');

    res = await fetch(`${BASE}/patients/token/${cardToken}/appointments/${rescheduleTarget.id}/reschedule/respond`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ accept: false }),
    });
    assert(res.status === 200, 'patient rejects the doctor-proposed reschedule');
    const afterReject = await res.json();
    assert(afterReject.status === 'confirmed', 'rejected reschedule returns to confirmed');
    assert(afterReject.starts_at === updated.starts_at, 'starts_at is unchanged after a rejection');
    assert(afterReject.proposed_by === null, 'proposed_by is cleared after a rejection');

    // Reschedule: patient proposes, doctor rejects -> original time stays.
    // Covers the two role/response combinations the assertions above don't:
    // a doctor calling /respond with accept:false, and (next) a patient
    // calling /respond with accept:true.
    res = await fetch(`${BASE}/clinics/${clinic.id}/availability?date=${aWeekOut}&doctorId=${doctorA.id}`);
    const { slots: slotsBeforePatientPropose } = await res.json();
    res = await fetch(`${BASE}/patients/token/${cardToken}/appointments/${rescheduleTarget.id}/reschedule`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ startsAt: `${aWeekOut} ${slotsBeforePatientPropose[0]}` }),
    });
    assert(res.status === 200, 'patient proposes a second reschedule');

    res = await fetch(`${BASE}/appointments/${rescheduleTarget.id}/reschedule/respond`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ accept: false }),
    });
    assert(res.status === 200, 'doctor rejects the patient-proposed reschedule');
    const afterDoctorReject = await res.json();
    assert(afterDoctorReject.status === 'confirmed', 'doctor-rejected reschedule returns to confirmed');
    assert(afterDoctorReject.starts_at === afterReject.starts_at,
      "starts_at is unchanged after the doctor's rejection");

    // Reschedule: doctor proposes, patient accepts -> new time takes effect.
    res = await fetch(`${BASE}/clinics/${clinic.id}/availability?date=${aWeekOut}&doctorId=${doctorA.id}`);
    const { slots: slotsBeforeDoctorPropose } = await res.json();
    res = await fetch(`${BASE}/appointments/${rescheduleTarget.id}/reschedule`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ startsAt: `${aWeekOut} ${slotsBeforeDoctorPropose[0]}` }),
    });
    assert(res.status === 200, 'doctor proposes a second reschedule');

    res = await fetch(`${BASE}/patients/token/${cardToken}/appointments/${rescheduleTarget.id}/reschedule/respond`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ accept: true }),
    });
    assert(res.status === 200, 'patient accepts the doctor-proposed reschedule');
    const afterPatientAccept = await res.json();
    assert(afterPatientAccept.status === 'confirmed', 'patient-accepted reschedule returns to confirmed');
    assert(afterPatientAccept.starts_at === `${aWeekOut} ${slotsBeforeDoctorPropose[0]}`,
      "starts_at moved to the doctor's proposed time");

    // Cross-patient scoping: card B cannot touch card A's appointment.
    res = await fetch(`${BASE}/patients/token/${cardToken2}/appointments/${rescheduleTarget.id}/reschedule`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ startsAt: `${aWeekOut} 09:00` }),
    });
    assert(res.status === 404, "another patient's card cannot propose a reschedule on this appointment");
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test`
Expected: FAIL — the reschedule endpoints don't exist yet (404s where 200 is expected).

- [ ] **Step 3: Implement**

In `server.js`, add after `POST /api/appointments/:id/decision` (currently ends at line ~1566, right before the `// --- NFC tap broadcast ---` comment):

```js
// --- Appointment rescheduling ---
//
// A confirmed appointment can be moved by either side proposing a new time;
// the other side must accept or reject before it takes effect. The original
// slot stays held throughout (see the reschedule_requested entry in
// HELD_STATUSES) so nobody else can grab it out from under the pending
// change.

/// Applies a reschedule response. Returns `null` on success, or
/// `{ status, error }` if accepting lost a race for the new slot — the
/// caller relays that straight back as the HTTP response.
function respondToReschedule(appointment, accept, doctorId, patientId) {
  if (!accept) {
    db.prepare(
      `UPDATE appointments
       SET status = 'confirmed', proposed_starts_at = NULL, proposed_by = NULL,
           reschedule_reason = NULL, updated_at = datetime('now')
       WHERE id = ?`
    ).run(appointment.id);
    logAudit(patientId, doctorId, 'appointment_reschedule_declined',
      `Kept original time ${appointment.starts_at}`);
    return null;
  }

  try {
    db.prepare(
      `UPDATE appointments
       SET status = 'confirmed', starts_at = proposed_starts_at,
           proposed_starts_at = NULL, proposed_by = NULL, reschedule_reason = NULL,
           decided_by = ?, decided_at = datetime('now'), updated_at = datetime('now')
       WHERE id = ?`
    ).run(doctorId, appointment.id);
  } catch (err) {
    if (String(err.message).includes('UNIQUE')) {
      return { status: 409, error: 'That slot has just been taken. Please choose another time.' };
    }
    throw err;
  }
  logAudit(patientId, doctorId, 'appointment_reschedule_accepted',
    `Moved to ${appointment.proposed_starts_at}`);
  return null;
}

app.post('/api/patients/token/:token/appointments/:id/reschedule', lookupLimiter, (req, res) => {
  const patient = resolvePatientFromReq(req);
  if (!patient) {
    return res.status(404).json({ error: 'No patient found for this card' });
  }

  const appointment = db.prepare(
    `SELECT * FROM appointments WHERE id = ? AND patient_id = ?`
  ).get(req.params.id, patient.id);
  if (!appointment) {
    return res.status(404).json({ error: 'Appointment not found' });
  }

  const allowed = ALLOWED_TRANSITIONS[appointment.status] ?? [];
  if (!allowed.includes('reschedule_requested')) {
    return res.status(409).json({
      error: `An appointment that is ${appointment.status} cannot be rescheduled.`,
    });
  }

  const clinic = db.prepare(`SELECT * FROM clinics WHERE id = ?`).get(appointment.clinic_id);
  const startsAt = normalizeStartsAt(req.body.startsAt);
  const problem = bookingError(clinic, startsAt);
  if (problem) {
    return res.status(400).json({ error: problem });
  }

  db.prepare(
    `UPDATE appointments
     SET status = 'reschedule_requested', proposed_starts_at = ?, proposed_by = 'patient',
         reschedule_reason = ?, updated_at = datetime('now')
     WHERE id = ?`
  ).run(startsAt, optionalText(req.body.reason), appointment.id);

  logAudit(patient.id, null, 'appointment_reschedule_proposed',
    `Patient proposed moving ${appointment.starts_at} to ${startsAt}`);
  res.json(appointmentById(appointment.id));
});

app.post('/api/appointments/:id/reschedule', requireDoctor, (req, res) => {
  const appointment = db.prepare(`SELECT * FROM appointments WHERE id = ?`).get(req.params.id);
  if (!appointment) {
    return res.status(404).json({ error: 'Appointment not found' });
  }

  const allowed = ALLOWED_TRANSITIONS[appointment.status] ?? [];
  if (!allowed.includes('reschedule_requested')) {
    return res.status(409).json({
      error: `An appointment that is ${appointment.status} cannot be rescheduled.`,
    });
  }

  const clinic = db.prepare(`SELECT * FROM clinics WHERE id = ?`).get(appointment.clinic_id);
  const startsAt = normalizeStartsAt(req.body.startsAt);
  const problem = bookingError(clinic, startsAt);
  if (problem) {
    return res.status(400).json({ error: problem });
  }

  db.prepare(
    `UPDATE appointments
     SET status = 'reschedule_requested', proposed_starts_at = ?, proposed_by = 'doctor',
         reschedule_reason = ?, updated_at = datetime('now')
     WHERE id = ?`
  ).run(startsAt, optionalText(req.body.reason), appointment.id);

  logAudit(appointment.patient_id, req.doctor.id, 'appointment_reschedule_proposed',
    `Doctor proposed moving ${appointment.starts_at} to ${startsAt}`);
  res.json(appointmentById(appointment.id));
});

app.post('/api/patients/token/:token/appointments/:id/reschedule/respond', lookupLimiter, (req, res) => {
  const patient = resolvePatientFromReq(req);
  if (!patient) {
    return res.status(404).json({ error: 'No patient found for this card' });
  }

  const appointment = db.prepare(
    `SELECT * FROM appointments WHERE id = ? AND patient_id = ?`
  ).get(req.params.id, patient.id);
  if (!appointment) {
    return res.status(404).json({ error: 'Appointment not found' });
  }
  if (appointment.status !== 'reschedule_requested' || appointment.proposed_by !== 'doctor') {
    return res.status(409).json({ error: 'No doctor-proposed reschedule is pending on this appointment.' });
  }

  const err = respondToReschedule(appointment, !!req.body.accept, null, patient.id);
  if (err) return res.status(err.status).json({ error: err.error });
  res.json(appointmentById(appointment.id));
});

app.post('/api/appointments/:id/reschedule/respond', requireDoctor, (req, res) => {
  const appointment = db.prepare(`SELECT * FROM appointments WHERE id = ?`).get(req.params.id);
  if (!appointment) {
    return res.status(404).json({ error: 'Appointment not found' });
  }
  if (appointment.status !== 'reschedule_requested' || appointment.proposed_by !== 'patient') {
    return res.status(409).json({ error: 'No patient-proposed reschedule is pending on this appointment.' });
  }

  const err = respondToReschedule(appointment, !!req.body.accept, req.doctor.id, appointment.patient_id);
  if (err) return res.status(err.status).json({ error: err.error });
  res.json(appointmentById(appointment.id));
});
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test`
Expected: PASS for every assertion added in this task.

- [ ] **Step 5: Commit**

```bash
git add server.js test/smoke.js
git commit -m "Add propose/respond endpoints for appointment rescheduling"
```

---

## Task 7: Reschedule suggestions endpoints (scoring + Gemini wired together)

**Files:**
- Modify: `server.js` (add near the Task 6 endpoints; require `reschedule.js` and `gemini.js` at the top)
- Test: `test/smoke.js` (append)

**Interfaces:**
- Consumes: `urgencyTag`, `rankCandidates` (`reschedule.js`); `rationalizeCandidates` (`gemini.js`); `availableSlots`, `toDateString` (`appointments.js`); `heldTimes` (Task 3).
- Produces: `GET .../reschedule/suggestions` (both variants) → `{ suggestions: [{ startsAt, patientFit, clinicFit, rationale }] }`.

- [ ] **Step 1: Write the failing test**

Append to `test/smoke.js`, after the Task 6 assertions:

```js
    // Suggestions: works for the doctor-scoped booking (doctorA), and for an
    // appointment with no doctor assigned at all (clinic-wide fallback).
    res = await fetch(`${BASE}/appointments/${rescheduleTarget.id}/reschedule/suggestions`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    assert(res.status === 200, 'doctor fetches reschedule suggestions');
    const { suggestions } = await res.json();
    assert(Array.isArray(suggestions) && suggestions.length > 0, 'suggestions is a non-empty array');
    assert(suggestions.every((s) => typeof s.startsAt === 'string' && typeof s.rationale === 'string'),
      'every suggestion has a startsAt and a rationale');
    // Use afterPatientAccept, not rescheduleTarget, for the current starts_at:
    // rescheduleTarget is the stale value captured right after booking, and
    // this appointment has moved twice since (Task 6's accept/reject dance).
    assert(!suggestions.some((s) => s.startsAt === afterPatientAccept.starts_at),
      'suggestions never include the slot already held by this appointment');

    res = await fetch(`${BASE}/patients/token/${cardToken}/appointments/${rescheduleTarget.id}/reschedule/suggestions`);
    assert(res.status === 200, 'patient fetches the same suggestions via their card');

    // No-doctor appointment still gets clinic-wide suggestions without erroring.
    res = await fetch(`${BASE}/patients/token/${cardToken}/appointments`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        clinicId: clinic.id,
        startsAt: `${aWeekOut} ${freshSlots[freshSlots.length - 1]}`,
        reason: 'No doctor assigned',
      }),
    });
    const noDoctorAppt = await res.json();
    await fetch(`${BASE}/appointments/${noDoctorAppt.id}/decision`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ status: 'confirmed' }),
    });
    res = await fetch(`${BASE}/patients/token/${cardToken}/appointments/${noDoctorAppt.id}/reschedule/suggestions`);
    assert(res.status === 200, 'an appointment with no assigned doctor still returns suggestions');
    const { suggestions: fallbackSuggestions } = await res.json();
    assert(Array.isArray(fallbackSuggestions) && fallbackSuggestions.length > 0,
      'clinic-wide fallback suggestions are non-empty');
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test`
Expected: FAIL — `/reschedule/suggestions` routes don't exist (404).

- [ ] **Step 3: Implement**

In `server.js`, add near the top with the other local requires (after the `require('./appointments')` block):

```js
const { urgencyTag, rankCandidates } = require('./reschedule');
const { rationalizeCandidates } = require('./gemini');
```

Add after the Task 6 endpoints:

```js
/// Average confirmed/completed appointments per day this doctor has actually
/// run over the last 30 days. Zero (meaning "no penalty applied") until
/// there's enough history to call anything "typical".
function averageDailyLoad(doctorId) {
  const row = db.prepare(
    `SELECT COUNT(*) AS n, COUNT(DISTINCT substr(starts_at, 1, 10)) AS days
     FROM appointments
     WHERE doctor_id = ? AND status IN ('confirmed', 'completed')
       AND starts_at >= datetime('now', '-30 days')`
  ).get(doctorId);
  return row.days > 0 ? row.n / row.days : 0;
}

function templatedRationale(candidate) {
  return candidate.clinicFit >= 80
    ? 'Fills an open slot in the schedule.'
    : 'Closest match to your original time.';
}

/// Builds the ranked, narrated suggestion list for one appointment. Shared by
/// both the patient-token and doctor-auth suggestions routes below.
async function buildRescheduleSuggestions(appointment) {
  const clinic = db.prepare(`SELECT * FROM clinics WHERE id = ?`).get(appointment.clinic_id);
  const patient = db.prepare(`SELECT * FROM patients WHERE id = ?`).get(appointment.patient_id);
  const hasChronicCondition = !!(patient.conditions && patient.conditions.trim());
  const tag = urgencyTag(appointment.reason, hasChronicCondition);

  const [origDate] = appointment.starts_at.split(' ');
  const start = new Date(`${origDate}T00:00:00`);
  const sameDayBookedTimesByDate = {};
  const candidates = [];
  for (let i = 1; i <= 14; i++) {
    const d = new Date(start);
    d.setDate(d.getDate() + i);
    const dateStr = toDateString(d);
    const taken = heldTimes(clinic.id, dateStr, appointment.doctor_id || undefined);
    sameDayBookedTimesByDate[dateStr] = taken;
    for (const time of availableSlots(clinic, dateStr, taken)) {
      candidates.push(`${dateStr} ${time}`);
    }
  }

  const typicalDailyLoad = appointment.doctor_id ? averageDailyLoad(appointment.doctor_id) : 0;

  const ranked = rankCandidates({
    originalStartsAt: appointment.starts_at,
    candidates,
    tag,
    sameDayBookedTimesByDate,
    slotMinutes: clinic.slot_minutes,
    typicalDailyLoad,
    now: new Date(),
    limit: 5,
  });

  const aiSuggestions = await rationalizeCandidates({
    originalStartsAt: appointment.starts_at,
    urgencyTag: tag,
    candidates: ranked,
  });

  return ranked.map((r, i) => ({
    startsAt: r.startsAt,
    patientFit: r.patientFit,
    clinicFit: r.clinicFit,
    rationale: aiSuggestions?.[i]?.rationale ?? templatedRationale(r),
  }));
}

app.get('/api/patients/token/:token/appointments/:id/reschedule/suggestions', lookupLimiter, async (req, res) => {
  const patient = resolvePatientFromReq(req);
  if (!patient) {
    return res.status(404).json({ error: 'No patient found for this card' });
  }
  const appointment = db.prepare(
    `SELECT * FROM appointments WHERE id = ? AND patient_id = ?`
  ).get(req.params.id, patient.id);
  if (!appointment) {
    return res.status(404).json({ error: 'Appointment not found' });
  }
  res.json({ suggestions: await buildRescheduleSuggestions(appointment) });
});

app.get('/api/appointments/:id/reschedule/suggestions', requireDoctor, async (req, res) => {
  const appointment = db.prepare(`SELECT * FROM appointments WHERE id = ?`).get(req.params.id);
  if (!appointment) {
    return res.status(404).json({ error: 'Appointment not found' });
  }
  res.json({ suggestions: await buildRescheduleSuggestions(appointment) });
});
```

Express 5 forwards a rejected promise from an async route handler to the error middleware automatically, so no manual `try`/`catch`/`next(err)` is needed here — and `buildRescheduleSuggestions` itself cannot reject anyway, since `rationalizeCandidates` never throws.

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test`
Expected: PASS for every assertion in this task. Since no `GEMINI_API_KEY` is set in the test environment, `rationalizeCandidates` returns `null` for every call and the templated rationale is what actually gets asserted on — this is expected and correct.

- [ ] **Step 5: Commit**

```bash
git add server.js test/smoke.js
git commit -m "Wire deterministic scoring and Gemini rationale into the suggestions endpoints"
```

---

## Task 8: Flutter API client methods

**Files:**
- Modify: `app/lib/api.dart`

**Interfaces:**
- Produces: `getClinicDoctors(clinicId)`, `getAvailability(clinicId, date, {doctorId})`, `bookAppointment(..., {doctorId})`, `updateDoctorProfile(..., {clinicId})`, `getRescheduleSuggestions(appointmentId, {cardToken})`, `proposeReschedule(appointmentId, startsAt, {cardToken})`, `respondToReschedule(appointmentId, accept, {cardToken})`.

No test step for this task — it's Dart plumbing exercised by the widget tests in later tasks and by manual verification once the screens exist. The signatures below are exact and load-bearing for those tasks.

- [ ] **Step 1: Update `getAvailability` and `bookAppointment` to accept an optional doctor**

In `app/lib/api.dart`, replace the existing `getAvailability` (currently at line ~871-880):

```dart
  /// The bookable start times ("HH:MM") at a clinic on [date] (YYYY-MM-DD),
  /// with slots already taken or now in the past removed. Scoped to
  /// [doctorId] when given, so two doctors at the same clinic don't share
  /// availability.
  Future<List<String>> getAvailability(int clinicId, String date, {int? doctorId}) async {
    final uri = Uri.parse('$_baseUrl/clinics/$clinicId/availability').replace(
      queryParameters: {
        'date': date,
        if (doctorId != null) 'doctorId': '$doctorId',
      },
    );
    final res = await http.get(uri, headers: _headers);
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not load availability');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return (body['slots'] as List<dynamic>).cast<String>();
  }
```

Replace the existing `bookAppointment` (currently at line ~888-907):

```dart
  /// Request an appointment against a card. Like readings, this needs no doctor
  /// login — card possession is the patient's credential. The booking lands as
  /// `requested` and holds its slot until a doctor confirms or rejects it.
  ///
  /// [startsAt] is clinic-local "YYYY-MM-DD HH:MM". Throws with the server's
  /// message on a clash (the slot was taken first) or invalid time.
  Future<Map<String, dynamic>> bookAppointment(
    String token, {
    required int clinicId,
    int? doctorId,
    required String startsAt,
    String? reason,
  }) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/patients/token/$token/appointments'),
      headers: _headersFor(token),
      body: jsonEncode({
        'clinicId': clinicId,
        if (doctorId != null) 'doctorId': doctorId,
        'startsAt': startsAt,
        if (reason != null && reason.isNotEmpty) 'reason': reason,
      }),
    );
    if (res.statusCode != 201) {
      throw _errorFrom(res, 'Could not book appointment');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
```

- [ ] **Step 2: Add `getClinicDoctors`**

Add right after `getClinics()` (currently ends at line ~867):

```dart
  /// Doctors assigned to a clinic, for the doctor-picker step of booking.
  Future<List<Map<String, dynamic>>> getClinicDoctors(int clinicId) async {
    final res = await http.get(
      Uri.parse('$_baseUrl/clinics/$clinicId/doctors'),
      headers: _headers,
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not load doctors');
    }
    return (jsonDecode(res.body) as List<dynamic>).cast<Map<String, dynamic>>();
  }
```

- [ ] **Step 3: Add `clinicId` to `updateDoctorProfile`**

Replace the existing `updateDoctorProfile` (currently at line ~112-131):

```dart
  Future<Map<String, dynamic>> updateDoctorProfile({
    String? name,
    String? email,
    String? phone,
    int? clinicId,
  }) async {
    final res = await http.put(
      Uri.parse('$_baseUrl/auth/me'),
      headers: _headers,
      body: jsonEncode({
        if (name != null) 'name': name,
        if (email != null) 'email': email,
        if (phone != null) 'phone': phone,
        if (clinicId != null) 'clinicId': clinicId,
      }),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not update profile');
    }
    final profile = jsonDecode(res.body) as Map<String, dynamic>;
    _doctor = profile;
    notifyListeners();
    return profile;
  }
```

(Keep whatever the existing trailing lines were — `_doctor = profile; notifyListeners(); return profile;` — matching what's already there today; only the parameter list and body map are new.)

- [ ] **Step 4: Add the reschedule methods**

Add after `decideAppointment` (currently ends at line ~977), still inside the `// --- Appointments ---` section:

```dart
  /// Ranked, AI-narrated alternative times for a confirmed appointment.
  /// [cardToken] identifies a patient call; omit it for a doctor-auth call.
  Future<List<Map<String, dynamic>>> getRescheduleSuggestions(
    int appointmentId, {
    String? cardToken,
  }) async {
    final path = cardToken != null
        ? '/patients/token/$cardToken/appointments/$appointmentId/reschedule/suggestions'
        : '/appointments/$appointmentId/reschedule/suggestions';
    final res = await http.get(
      Uri.parse('$_baseUrl$path'),
      headers: cardToken != null ? _headersFor(cardToken) : _headers,
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not load reschedule suggestions');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return (body['suggestions'] as List<dynamic>).cast<Map<String, dynamic>>();
  }

  /// Proposes a new time for a confirmed appointment. The other side must
  /// accept it via [respondToReschedule] before it takes effect.
  Future<Map<String, dynamic>> proposeReschedule(
    int appointmentId,
    String startsAt, {
    String? cardToken,
  }) async {
    final path = cardToken != null
        ? '/patients/token/$cardToken/appointments/$appointmentId/reschedule'
        : '/appointments/$appointmentId/reschedule';
    final res = await http.post(
      Uri.parse('$_baseUrl$path'),
      headers: cardToken != null ? _headersFor(cardToken) : _headers,
      body: jsonEncode({'startsAt': startsAt}),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not propose a new time');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Accepts or rejects a reschedule the other side proposed.
  Future<Map<String, dynamic>> respondToReschedule(
    int appointmentId,
    bool accept, {
    String? cardToken,
  }) async {
    final path = cardToken != null
        ? '/patients/token/$cardToken/appointments/$appointmentId/reschedule/respond'
        : '/appointments/$appointmentId/reschedule/respond';
    final res = await http.post(
      Uri.parse('$_baseUrl$path'),
      headers: cardToken != null ? _headersFor(cardToken) : _headers,
      body: jsonEncode({'accept': accept}),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not respond to the reschedule request');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
```

- [ ] **Step 5: Verify the app still analyzes cleanly**

Run: `cd app && flutter analyze`
Expected: no new errors introduced by this file (pre-existing warnings elsewhere are out of scope).

- [ ] **Step 6: Commit**

```bash
git add app/lib/api.dart
git commit -m "Add Flutter API client methods for doctor-scoped booking and rescheduling"
```

---

## Task 9: Shared `SlotGrid` widget and `reschedule_requested` status style

**Files:**
- Modify: `app/lib/widgets.dart` (add `SlotGrid`, add a `reschedule_requested` case to `AppointmentStatusStyle.of`)
- Modify: `app/lib/screens/appointments/book_appointment_screen.dart` (use the shared `SlotGrid` instead of its private `_SlotGrid`)

**Interfaces:**
- Produces: `SlotGrid({required Future<List<String>> slots, required String? selected, required ValueChanged<String> onSelect})`, reused by `book_appointment_screen.dart` and the new `reschedule_screen.dart` in Task 10.

- [ ] **Step 1: Add the `reschedule_requested` status style**

In `app/lib/widgets.dart`, in `AppointmentStatusStyle.of` (currently at line ~95-115), add a case before `default`:

```dart
      case 'reschedule_requested':
        return const AppointmentStatusStyle(
            'Reschedule pending', Color(0xFF9C6ADE), Icons.sync_alt);
```

- [ ] **Step 2: Extract `SlotGrid` as a public widget**

In `app/lib/widgets.dart`, add (anywhere alongside the other shared widgets, e.g. after `StatusPill`'s class body):

```dart
/// A wrap of choice chips for the bookable "HH:MM" times on one day, shared
/// by the booking flow and the reschedule flow.
class SlotGrid extends StatelessWidget {
  const SlotGrid({
    super.key,
    required this.slots,
    required this.selected,
    required this.onSelect,
  });

  final Future<List<String>> slots;
  final String? selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<List<String>>(
      future: slots,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError) {
          return Text(snap.error.toString().replaceFirst('Exception: ', ''),
              style: TextStyle(color: scheme.error));
        }
        final times = snap.data ?? const [];
        if (times.isEmpty) {
          return Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'No open slots on this day. Try another date.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          );
        }
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t in times)
              ChoiceChip(
                label: Text(t),
                selected: selected == t,
                onSelected: (_) => onSelect(t),
              ),
          ],
        );
      },
    );
  }
}
```

- [ ] **Step 3: Remove the private duplicate from `book_appointment_screen.dart` and use the shared one**

In `app/lib/screens/appointments/book_appointment_screen.dart`:

- Delete the entire private `_SlotGrid` class (currently lines 359-416, from `class _SlotGrid extends StatelessWidget {` to its closing `}`).
- Replace the usage `_SlotGrid(` (currently at line ~191) with `SlotGrid(` — same named arguments (`slots:`, `selected:`, `onSelect:`), no other change.
- Add `import '../../widgets.dart';` if not already imported (it already is, at line 3 — no change needed there).

- [ ] **Step 4: Verify the app still analyzes and the existing booking screen still renders**

Run: `cd app && flutter analyze`
Expected: no errors (the old `_SlotGrid` reference is gone, the new `SlotGrid` import already resolves via the existing `widgets.dart` import).

Run: `cd app && flutter test test/widget_test.dart`
Expected: PASS (this is the existing baseline smoke test; confirms the app still builds a widget tree).

- [ ] **Step 5: Commit**

```bash
git add app/lib/widgets.dart app/lib/screens/appointments/book_appointment_screen.dart
git commit -m "Extract a shared SlotGrid widget and add the reschedule_requested status style"
```

---

## Task 10: Doctor picker in the booking flow

**Files:**
- Modify: `app/lib/screens/appointments/book_appointment_screen.dart`

**Interfaces:**
- Consumes: `MedThruApi.instance.getClinicDoctors(clinicId)`, `getAvailability(clinicId, date, {doctorId})`, `bookAppointment(..., {doctorId})` (Task 8).

- [ ] **Step 1: Add doctor state and loading**

In `_BookAppointmentScreenState`, add alongside the existing `_clinic`/`_date` fields:

```dart
  Future<List<Map<String, dynamic>>>? _doctors;
  Map<String, dynamic>? _doctor;
```

- [ ] **Step 2: Load doctors when a clinic is picked, and re-scope slot loading**

Replace `_selectClinic` and `_loadSlots`:

```dart
  void _selectClinic(Map<String, dynamic>? clinic) {
    setState(() {
      _clinic = clinic;
      _doctor = null;
      _slot = null;
      _error = null;
      _doctors = clinic == null ? null : _api.getClinicDoctors(clinic['id'] as int);
      _doctors?.ignore();
      _loadSlots();
    });
  }

  void _selectDoctor(Map<String, dynamic>? doctor) {
    setState(() {
      _doctor = doctor;
      _slot = null;
      _error = null;
      _loadSlots();
    });
  }

  void _loadSlots() {
    if (_clinic == null) {
      _slots = null;
      return;
    }
    _slots = _api.getAvailability(
      _clinic!['id'] as int,
      _dateStr,
      doctorId: _doctor?['id'] as int?,
    );
    _slots!.ignore(); // handled by the FutureBuilder; silence unawaited-error
  }
```

- [ ] **Step 3: Insert a doctor-selection step between clinic and date**

In `build()`, after the `if (_clinic != null) ...[` block's opening (right after the `const SizedBox(height: 24)` that follows the clinic list, currently at line ~177-178), insert:

```dart
              const SizedBox(height: 24),
              _StepLabel(n: 2, text: 'Choose a doctor (optional)'),
              const SizedBox(height: 10),
              FutureBuilder<List<Map<String, dynamic>>>(
                future: _doctors,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final doctors = snap.data ?? const [];
                  if (doctors.isEmpty) {
                    return Text('No doctors listed at this clinic yet — any available doctor will see you.',
                        style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant));
                  }
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final d in doctors)
                        ChoiceChip(
                          label: Text(d['name'] as String),
                          selected: _doctor?['id'] == d['id'],
                          onSelected: (selected) => _selectDoctor(selected ? d : null),
                        ),
                    ],
                  );
                },
              ),
```

Then renumber the remaining `_StepLabel` calls in this screen (`Pick a date` becomes step 3, `Pick a time` becomes step 4, `Reason for visit` becomes step 5) by updating their `n:` arguments accordingly.

- [ ] **Step 4: Pass the chosen doctor through to booking**

In `_book()`, update the call to `_api.bookAppointment`:

```dart
      final appt = await _api.bookAppointment(
        widget.cardToken,
        clinicId: _clinic!['id'] as int,
        doctorId: _doctor?['id'] as int?,
        startsAt: '$_dateStr $_slot',
        reason: _reason.text.trim(),
      );
```

- [ ] **Step 5: Manually verify**

Run the app (`cd app && flutter run -d windows`), sign in as a patient, and walk through booking: pick a clinic, confirm the doctor chips load (empty state reads correctly if no doctor is assigned to that clinic yet), pick a doctor, confirm slot availability changes when switching between doctors, complete a booking, and confirm the resulting appointment shows the doctor's name on the appointments screen (it won't display it yet — that's Task 12 — just confirm the API call in step 4 doesn't error).

- [ ] **Step 6: Commit**

```bash
git add app/lib/screens/appointments/book_appointment_screen.dart
git commit -m "Add a doctor-selection step to the booking flow"
```

---

## Task 11: Clinic picker in doctor settings

**Files:**
- Modify: `app/lib/screens/doctor/doctor_settings_screen.dart`

**Interfaces:**
- Consumes: `MedThruApi.instance.getClinics()`, `updateDoctorProfile(..., clinicId: ...)` (Task 8).

- [ ] **Step 1: Add clinic state and loading**

In `_DoctorSettingsScreenState`, add alongside the existing controllers:

```dart
  late Future<List<Map<String, dynamic>>> _clinics;
  int? _clinicId;
```

In `initState()`, after the existing `_phone.text = ...` line:

```dart
    _clinicId = doctor?['clinic_id'] as int?;
    _clinics = _api.getClinics();
    _clinics.ignore();
```

- [ ] **Step 2: Add a clinic picker to the profile section, and send it on save**

In `build()`, after the phone `TextField` (currently ends at line ~142) and before the `if (_profileError != null)` block, insert:

```dart
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
```

Update `_saveProfile()` to send it:

```dart
      await _api.updateDoctorProfile(
        name: _name.text.trim(),
        email: _email.text.trim(),
        phone: _phone.text.trim(),
        clinicId: _clinicId,
      );
```

- [ ] **Step 3: Manually verify**

Run: `cd app && flutter test app/test/doctor_settings_test.dart`
Expected: PASS — the existing prefill/validation tests don't touch the clinic picker and shouldn't be affected by it, since `_clinics` is a real network call the tests don't await (`FutureBuilder`'s `snap.data` is simply `null`/empty during the test, which the picker already handles as an empty `Wrap`).

Then run the app, sign in as a doctor, open Settings, confirm the clinic chips load and selecting one and saving persists across a re-login.

- [ ] **Step 4: Commit**

```bash
git add app/lib/screens/doctor/doctor_settings_screen.dart
git commit -m "Let a doctor self-assign to a clinic from Settings"
```

---

## Task 12: `RescheduleScreen`

**Files:**
- Create: `app/lib/screens/appointments/reschedule_screen.dart`
- Test: `app/test/reschedule_screen_test.dart` (new)

**Interfaces:**
- Consumes: `SlotGrid` (Task 9), `MedThruApi.instance.{getRescheduleSuggestions, proposeReschedule, getClinics, getAvailability}` (Task 8), `formatAppointmentTime` (existing, `widgets.dart`).
- Produces: `RescheduleScreen({required appointment, cardToken})` — `cardToken == null` means doctor mode. Pops with the updated appointment map on success, `null` on cancel.

- [ ] **Step 1: Write the failing test**

Create `app/test/reschedule_screen_test.dart`:

```dart
// Widget test for RescheduleScreen: confirms it renders in both patient and
// doctor mode and shows a loading state before the suggestions future
// resolves, without requiring a real network call.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:medthru_app/api.dart';
import 'package:medthru_app/screens/appointments/reschedule_screen.dart';

void main() {
  final appointment = {
    'id': 1,
    'starts_at': '2026-09-25 10:00',
    'clinic_name': 'Test Clinic',
    'status': 'confirmed',
  };

  tearDown(() => MedThruApi.instance.debugSetSession());

  testWidgets('Patient mode shows a loading indicator before suggestions arrive',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: RescheduleScreen(appointment: appointment, cardToken: 'fake-card-token'),
    ));

    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(find.text('Reschedule appointment'), findsOneWidget);
  });

  testWidgets('Doctor mode shows a loading indicator before suggestions arrive',
      (tester) async {
    MedThruApi.instance.debugSetSession(
      token: 'fake-doctor-token',
      doctor: {'id': 1, 'name': 'Dr. Test', 'email': 'test@medthru.test'},
    );
    await tester.pumpWidget(MaterialApp(
      home: RescheduleScreen(appointment: appointment, cardToken: null),
    ));

    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(find.text('Reschedule appointment'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app && flutter test test/reschedule_screen_test.dart`
Expected: FAIL — `reschedule_screen.dart` doesn't exist yet.

- [ ] **Step 3: Implement `RescheduleScreen`**

Create `app/lib/screens/appointments/reschedule_screen.dart`:

```dart
import 'package:flutter/material.dart';
import '../../api.dart';
import '../../widgets.dart';

/// Propose a new time for a confirmed appointment, choosing from AI-ranked
/// suggestions or picking a slot manually. Used by both apps: [cardToken]
/// non-null means patient mode (reached with the card), null means doctor
/// mode (reached with the doctor's session).
class RescheduleScreen extends StatefulWidget {
  const RescheduleScreen({super.key, required this.appointment, this.cardToken});

  final Map<String, dynamic> appointment;
  final String? cardToken;

  @override
  State<RescheduleScreen> createState() => _RescheduleScreenState();
}

class _RescheduleScreenState extends State<RescheduleScreen> {
  final _api = MedThruApi.instance;
  late Future<List<Map<String, dynamic>>> _suggestions;

  bool _manualPickerOpen = false;
  DateTime _date = _today();
  Future<List<String>>? _manualSlots;
  String? _manualSlot;

  bool _submitting = false;
  String? _error;

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  String get _dateStr =>
      '${_date.year.toString().padLeft(4, '0')}-'
      '${_date.month.toString().padLeft(2, '0')}-'
      '${_date.day.toString().padLeft(2, '0')}';

  int get _appointmentId => widget.appointment['id'] as int;
  int get _clinicId => widget.appointment['clinic_id'] as int;
  int? get _doctorId => widget.appointment['doctor_id'] as int?;

  @override
  void initState() {
    super.initState();
    _suggestions = _api.getRescheduleSuggestions(_appointmentId, cardToken: widget.cardToken);
    _suggestions.ignore();
  }

  void _openManualPicker() {
    setState(() {
      _manualPickerOpen = true;
      _manualSlots = _api.getAvailability(_clinicId, _dateStr, doctorId: _doctorId);
      _manualSlots!.ignore();
    });
  }

  Future<void> _pickManualDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: _today(),
      lastDate: _today().add(const Duration(days: 90)),
    );
    if (picked != null) {
      setState(() {
        _date = picked;
        _manualSlot = null;
        _manualSlots = _api.getAvailability(_clinicId, _dateStr, doctorId: _doctorId);
        _manualSlots!.ignore();
      });
    }
  }

  Future<void> _propose(String startsAt) async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final updated = await _api.proposeReschedule(
        _appointmentId,
        startsAt,
        cardToken: widget.cardToken,
      );
      if (!mounted) return;
      Navigator.pop(context, updated);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Reschedule appointment')),
      body: BoundedBody(
        maxWidth: 640,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'Currently at ${formatAppointmentTime(widget.appointment['starts_at'] as String)}.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Text('Suggested times',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: scheme.onSurface)),
            const SizedBox(height: 10),
            FutureBuilder<List<Map<String, dynamic>>>(
              future: _suggestions,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snap.hasError) {
                  return Text(snap.error.toString().replaceFirst('Exception: ', ''),
                      style: TextStyle(color: scheme.error));
                }
                final suggestions = snap.data ?? const [];
                if (suggestions.isEmpty) {
                  return Text('No suggested times right now — pick one manually below.',
                      style: TextStyle(color: scheme.onSurfaceVariant));
                }
                return Column(
                  children: [
                    for (final s in suggestions)
                      Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          title: Text(formatAppointmentTime(s['startsAt'] as String)),
                          subtitle: Text(s['rationale'] as String),
                          trailing: FilledButton(
                            onPressed: _submitting ? null : () => _propose(s['startsAt'] as String),
                            child: const Text('Choose'),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 20),
            if (!_manualPickerOpen)
              OutlinedButton.icon(
                onPressed: _openManualPicker,
                icon: const Icon(Icons.edit_calendar_outlined),
                label: const Text('Pick a different time manually'),
              )
            else ...[
              Text('Pick a time manually',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: scheme.onSurface)),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _pickManualDate,
                icon: const Icon(Icons.calendar_month_outlined),
                label: Text(formatAppointmentTime('$_dateStr 00:00').split(',').first),
              ),
              const SizedBox(height: 12),
              SlotGrid(
                slots: _manualSlots!,
                selected: _manualSlot,
                onSelect: (s) => setState(() => _manualSlot = s),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: (_manualSlot == null || _submitting)
                    ? null
                    : () => _propose('$_dateStr $_manualSlot'),
                icon: _submitting
                    ? const SizedBox(
                        height: 18, width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.event_available),
                label: Text(_submitting ? 'Proposing…' : 'Propose this time'),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  Icon(Icons.error_outline, size: 18, color: scheme.error),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_error!, style: TextStyle(color: scheme.error))),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Text(
              'The other side needs to accept this before it takes effect. '
              'Your current time is held until then.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app && flutter test test/reschedule_screen_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/screens/appointments/reschedule_screen.dart app/test/reschedule_screen_test.dart
git commit -m "Add the shared RescheduleScreen for patient and doctor flows"
```

---

## Task 13: Wire reschedule into the patient appointments screen

**Files:**
- Modify: `app/lib/screens/patient/appointments_screen.dart`

**Interfaces:**
- Consumes: `RescheduleScreen` (Task 12), `MedThruApi.instance.respondToReschedule` (Task 8).

- [ ] **Step 1: Add the Reschedule action and the doctor-proposed banner**

In `app/lib/screens/patient/appointments_screen.dart`, add an import:

```dart
import 'reschedule_screen.dart';
```
(alongside the existing `import '../appointments/book_appointment_screen.dart';` — note this file already lives in `screens/patient/`, so the relative path to the new screen in `screens/appointments/` is `'../appointments/reschedule_screen.dart'`.)

Add a handler method in `_AppointmentsScreenState`, alongside `_cancel`:

```dart
  Future<void> _reschedule(Map<String, dynamic> appt) async {
    final updated = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => RescheduleScreen(appointment: appt, cardToken: widget.cardToken),
      ),
    );
    if (updated != null && mounted) {
      setState(_load);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reschedule proposed — waiting on the clinic to confirm.')),
      );
    }
  }

  Future<void> _respondToReschedule(Map<String, dynamic> appt, bool accept) async {
    try {
      await MedThruApi.instance.respondToReschedule(
        appt['id'] as int,
        accept,
        cardToken: widget.cardToken,
      );
      if (!mounted) return;
      setState(_load);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(accept ? 'New time accepted.' : 'Kept your original time.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }
```

In the `for (final a in appts)` loop in `build()`, replace the single `_AppointmentCard(...)` construction with a conditional: a doctor-proposed banner card when pending, otherwise the normal card with the new Reschedule action:

```dart
                for (final a in appts)
                  if (a['status'] == 'reschedule_requested' && a['proposed_by'] == 'doctor')
                    _ReschedulePendingCard(
                      appt: a,
                      onAccept: () => _respondToReschedule(a, true),
                      onDecline: () => _respondToReschedule(a, false),
                    )
                  else
                    _AppointmentCard(
                      appt: a,
                      onCancel: _cancellable.contains(a['status']) ? () => _cancel(a) : null,
                      onReschedule: a['status'] == 'confirmed' ? () => _reschedule(a) : null,
                      remindOn: _reminding.contains(a['id'] as int),
                      onToggleRemind:
                          a['status'] == 'confirmed' &&
                              DateTime.parse(a['starts_at'] as String).isAfter(DateTime.now())
                          ? () => _toggleReminder(a)
                          : null,
                      onAddToCalendar:
                          _cancellable.contains(a['status']) &&
                              DateTime.parse(a['starts_at'] as String).isAfter(DateTime.now())
                          ? () => exportAppointmentToCalendar(context, a)
                          : null,
                    ),
```

- [ ] **Step 2: Add `onReschedule` to `_AppointmentCard` and the new `_ReschedulePendingCard`**

In `_AppointmentCard`, add a field and constructor parameter:

```dart
class _AppointmentCard extends StatelessWidget {
  const _AppointmentCard({
    required this.appt,
    this.onCancel,
    this.onReschedule,
    this.remindOn = false,
    this.onToggleRemind,
    this.onAddToCalendar,
  });

  final Map<String, dynamic> appt;
  final VoidCallback? onCancel;
  final VoidCallback? onReschedule;
```

In its `build()`, in the actions `Wrap` (the one gated by `if (onToggleRemind != null || onAddToCalendar != null || onCancel != null)`), extend that condition and add the button:

```dart
            if (onToggleRemind != null ||
                onAddToCalendar != null ||
                onReschedule != null ||
                onCancel != null) ...[
              const SizedBox(height: 6),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 4,
                children: [
                  if (onAddToCalendar != null)
                    TextButton.icon(
                      onPressed: onAddToCalendar,
                      icon: const Icon(Icons.event_available_outlined, size: 16),
                      label: const Text('Add to calendar'),
                    ),
                  if (onToggleRemind != null)
                    TextButton.icon(
                      onPressed: onToggleRemind,
                      icon: Icon(remindOn ? Icons.notifications_active : Icons.notifications_outlined),
                      label: Text(remindOn ? 'Reminder on' : 'Remind me'),
                    ),
                  if (onReschedule != null)
                    TextButton.icon(
                      onPressed: onReschedule,
                      icon: const Icon(Icons.sync_alt, size: 16),
                      label: const Text('Reschedule'),
                    ),
                  if (onCancel != null)
                    TextButton.icon(
                      onPressed: onCancel,
                      icon: const Icon(Icons.close, size: 16),
                      label: const Text('Cancel'),
                      style: TextButton.styleFrom(foregroundColor: scheme.error),
                    ),
                ],
              ),
            ],
```

(This replaces the existing `Wrap` block; the `remindOn`/`onToggleRemind` icon line loses its explicit `size: 16` in the snippet above only for brevity — keep the original `Icon(...)` exactly as it already is today and just add the `onReschedule` branch alongside it.)

Add the new banner widget at the bottom of the file, alongside `_AppointmentCard`:

```dart
/// Shown instead of the normal appointment card when the clinic has proposed
/// a new time and is waiting on the patient to accept or decline it.
class _ReschedulePendingCard extends StatelessWidget {
  const _ReschedulePendingCard({
    required this.appt,
    required this.onAccept,
    required this.onDecline,
  });

  final Map<String, dynamic> appt;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.sync_alt, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('${appt['clinic_name']} wants to move your appointment',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('From ${formatAppointmentTime(appt['starts_at'] as String)}'),
            Text('To ${formatAppointmentTime(appt['proposed_starts_at'] as String)}'),
            const SizedBox(height: 10),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                OutlinedButton(onPressed: onDecline, child: const Text('Keep original time')),
                FilledButton(onPressed: onAccept, child: const Text('Accept new time')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 3: Manually verify**

Run: `cd app && flutter analyze`
Expected: no new errors.

Run the app as a patient with a confirmed appointment. Confirm the Reschedule button opens `RescheduleScreen` and completing it returns to a list showing `Reschedule pending` (from Task 9's status style). As a doctor, propose a reschedule on that same appointment (once Task 14 exists) and confirm the patient app shows `_ReschedulePendingCard` with working Accept/Decline.

- [ ] **Step 4: Commit**

```bash
git add app/lib/screens/patient/appointments_screen.dart
git commit -m "Add reschedule action and doctor-proposed banner to the patient appointments screen"
```

---

## Task 14: Wire reschedule into the doctor appointment queue

**Files:**
- Modify: `app/lib/screens/doctor/appointment_queue_screen.dart`

**Interfaces:**
- Consumes: `RescheduleScreen` (Task 12), `MedThruApi.instance.respondToReschedule` (Task 8).

- [ ] **Step 1: Add the filter tab and handlers**

In `app/lib/screens/doctor/appointment_queue_screen.dart`, add an import:

```dart
import '../appointments/reschedule_screen.dart';
```

Add the new filter to `_filters`:

```dart
  static const _filters = [
    ('requested', 'Pending'),
    ('reschedule_requested', 'Reschedule pending'),
    ('confirmed', 'Confirmed'),
    ('completed', 'Completed'),
    ('rejected', 'Rejected'),
    ('cancelled', 'Cancelled'),
  ];
```

Add handler methods in `_AppointmentQueueScreenState`, alongside `_decide`:

```dart
  Future<void> _reschedule(Map<String, dynamic> appt) async {
    final updated = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(builder: (_) => RescheduleScreen(appointment: appt)),
    );
    if (updated != null && mounted) {
      setState(_load);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reschedule proposed — waiting on the patient to confirm.')),
      );
    }
  }

  Future<void> _respondToReschedule(Map<String, dynamic> appt, bool accept) async {
    try {
      await MedThruApi.instance.respondToReschedule(appt['id'] as int, accept);
      if (!mounted) return;
      setState(_load);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(accept ? 'New time accepted.' : 'Kept the original time.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }
```

- [ ] **Step 2: Pass reschedule actions into `_QueueCard`**

In `build()`, update the `_QueueCard` construction:

```dart
                        for (final a in appts)
                          _QueueCard(
                            appt: a,
                            onConfirm: a['status'] == 'requested'
                                ? () => _decide(a, 'confirmed', 'confirmed')
                                : null,
                            onReject: a['status'] == 'requested'
                                ? () => _decide(a, 'rejected', 'rejected')
                                : null,
                            onComplete: a['status'] == 'confirmed'
                                ? () => _decide(a, 'completed', 'marked complete')
                                : null,
                            onCancel: (a['status'] == 'confirmed')
                                ? () => _decide(a, 'cancelled', 'cancelled')
                                : null,
                            onReschedule: a['status'] == 'confirmed'
                                ? () => _reschedule(a)
                                : null,
                            onAcceptReschedule:
                                a['status'] == 'reschedule_requested' && a['proposed_by'] == 'patient'
                                    ? () => _respondToReschedule(a, true)
                                    : null,
                            onDeclineReschedule:
                                a['status'] == 'reschedule_requested' && a['proposed_by'] == 'patient'
                                    ? () => _respondToReschedule(a, false)
                                    : null,
                          ),
```

- [ ] **Step 3: Extend `_QueueCard` to show the new actions**

Add fields to `_QueueCard`:

```dart
class _QueueCard extends StatelessWidget {
  const _QueueCard({
    required this.appt,
    this.onConfirm,
    this.onReject,
    this.onComplete,
    this.onCancel,
    this.onReschedule,
    this.onAcceptReschedule,
    this.onDeclineReschedule,
  });

  final Map<String, dynamic> appt;
  final VoidCallback? onConfirm;
  final VoidCallback? onReject;
  final VoidCallback? onComplete;
  final VoidCallback? onCancel;
  final VoidCallback? onReschedule;
  final VoidCallback? onAcceptReschedule;
  final VoidCallback? onDeclineReschedule;
```

In `build()`, update the `hasActions` check and the actions `Wrap`:

```dart
    final hasActions = onConfirm != null ||
        onReject != null ||
        onComplete != null ||
        onCancel != null ||
        onReschedule != null ||
        onAcceptReschedule != null ||
        onDeclineReschedule != null;
```

And inside the `if (hasActions) ...[` block's `Wrap` children, add (alongside the existing `onReject`/`onCancel`/`onComplete`/`onConfirm` buttons):

```dart
                  if (onDeclineReschedule != null)
                    TextButton.icon(
                      onPressed: onDeclineReschedule,
                      icon: const Icon(Icons.close, size: 18),
                      label: const Text('Keep original time'),
                      style: TextButton.styleFrom(foregroundColor: scheme.error),
                    ),
                  if (onAcceptReschedule != null)
                    FilledButton.icon(
                      onPressed: onAcceptReschedule,
                      icon: const Icon(Icons.check, size: 18),
                      label: const Text('Accept new time'),
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                    ),
                  if (onReschedule != null)
                    TextButton.icon(
                      onPressed: onReschedule,
                      icon: const Icon(Icons.sync_alt, size: 18),
                      label: const Text('Propose reschedule'),
                    ),
```

When an appointment is `reschedule_requested` and `proposed_by == 'patient'`, add a line showing the proposed time so the doctor has context before accepting/declining. In `build()`, alongside the existing `_line(scheme, Icons.schedule, ...)` call, add:

```dart
            if (appt['status'] == 'reschedule_requested' && appt['proposed_starts_at'] != null) ...[
              const SizedBox(height: 4),
              _line(scheme, Icons.sync_alt,
                  'Patient proposed ${formatAppointmentTime(appt['proposed_starts_at'] as String)}'),
            ],
```

- [ ] **Step 4: Manually verify**

Run: `cd app && flutter analyze`
Expected: no new errors.

Run the app as a doctor. Confirm the new "Reschedule pending" filter tab shows appointments in that state, "Propose reschedule" on a confirmed appointment opens `RescheduleScreen`, and a patient-proposed reschedule shows the proposed time plus working Accept/Decline buttons.

- [ ] **Step 5: Commit**

```bash
git add app/lib/screens/doctor/appointment_queue_screen.dart
git commit -m "Add reschedule filter, propose action, and accept/decline to the doctor queue"
```

---

## Task 15: Full-flow verification

**Files:** none (verification only)

- [ ] **Step 1: Run the full backend test suite**

Run: `npm test`
Expected: PASS — `reschedule-scoring.js`, `gemini.js`, and `smoke.js` all green.

- [ ] **Step 2: Run the full Flutter test suite**

Run: `cd app && flutter test`
Expected: PASS — no regressions in the pre-existing suite, plus the new `reschedule_screen_test.dart`.

- [ ] **Step 3: Manual end-to-end pass**

With a real `GEMINI_API_KEY` in `.env` (optional — the fallback path is already covered by the automated tests): run the backend (`npm start`), run the app, and walk through the full loop once: book an appointment against a specific doctor → confirm it as that doctor → propose a reschedule as the patient → see AI-narrated suggestions (or the templated fallback if no key is set) → accept it as the doctor → confirm the patient's appointment list shows the new time. Then repeat once with the doctor proposing and the patient accepting.

- [ ] **Step 4: Update the phase 1 proposal's implementation status table if this ships before the next proposal revision**

Optional — only if you're actively maintaining `docs/phase1-proposal.md` for the competition submission. Not required for this feature to be complete.
