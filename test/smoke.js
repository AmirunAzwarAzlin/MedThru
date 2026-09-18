// End-to-end smoke test for the backend: spins up server.js against a clean
// database, exercises the golden path (register a doctor, register a
// patient, look up by card, add a health record, confirm admin-gating),
// then tears down. No framework — just assertions and a nonzero exit code
// on failure, so it's cheap to run in CI.
'use strict';

const { spawn } = require('node:child_process');
const path = require('node:path');
const fs = require('node:fs');

const ROOT = path.join(__dirname, '..');
const DB_PATH = path.join(ROOT, 'medthru.db');
const BASE = 'http://localhost:3000/api';

// Start from a clean database so the test is deterministic regardless of
// what's been played with locally.
for (const suffix of ['', '-journal', '-wal', '-shm']) {
  fs.rmSync(DB_PATH + suffix, { force: true });
}

function waitForServer(proc) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('server did not start in time')), 10_000);
    proc.stdout.on('data', (chunk) => {
      process.stdout.write(chunk);
      if (chunk.toString().includes('listening')) {
        clearTimeout(timeout);
        resolve();
      }
    });
    proc.stderr.on('data', (chunk) => process.stderr.write(chunk));
    proc.on('exit', (code) => {
      clearTimeout(timeout);
      reject(new Error(`server exited early with code ${code}`));
    });
  });
}

function assert(condition, message) {
  if (!condition) throw new Error(`FAIL: ${message}`);
  console.log(`ok - ${message}`);
}

async function main() {
  const proc = spawn(process.execPath, ['server.js'], { cwd: ROOT });

  try {
    await waitForServer(proc);

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

    // Doctor registration and login.
    let res = await fetch(`${BASE}/auth/register-doctor`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        name: 'CI Doctor',
        licenseNumber: 'CI-001',
        email: 'ci@medthru.test',
        password: 'ci-password-123',
      }),
    });
    assert(res.status === 201, 'register a doctor');
    const { token } = await res.json();

    // A freshly registered doctor is not an administrator.
    res = await fetch(`${BASE}/patients/1/cards/reissue`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}` },
    });
    assert(res.status === 403, 'a non-admin doctor is blocked from card reissue');

    // Patient registration issues a card token exactly once.
    res = await fetch(`${BASE}/patients`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ full_name: 'CI Patient' }),
    });
    assert(res.status === 201, 'register a patient');
    const { patient, cardToken } = await res.json();
    assert(!('password_hash' in patient), 'patient response never carries a password hash');

    // Card-token lookup, the NFC-tap path.
    res = await fetch(`${BASE}/patients/token/${cardToken}`);
    assert(res.status === 200, 'look up the patient by card token');

    // Health records: add as the cardholder, confirm it shows up in the
    // doctor-side listing by patient id.
    res = await fetch(`${BASE}/patients/token/${cardToken}/allergies`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ allergen: 'Penicillin', severity: 'Moderate' }),
    });
    assert(res.status === 201, 'add an allergy with the card token');

    res = await fetch(`${BASE}/patients/${patient.id}/allergies`);
    const allergies = await res.json();
    assert(allergies.length === 1 && allergies[0].allergen === 'Penicillin',
      'the allergy shows up in the doctor-side listing');

    // Appointments: browse clinics (seeded on first boot), book, then cancel.
    // Pick a clinic open every day of the week, and a date a week out — using
    // "today" would make the outcome depend on what day and time this test
    // happens to run (today's hours may already be closed, or fall on a day
    // the clinic isn't open).
    res = await fetch(`${BASE}/clinics`);
    const clinics = await res.json();
    assert(clinics.length > 0, 'clinics are seeded on first boot');
    const clinic = clinics.find((c) => c.open_days === '1,2,3,4,5,6,7');
    assert(clinic, 'a clinic open every day exists to book against');

    const aWeekOut = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000)
      .toISOString().slice(0, 10);
    res = await fetch(`${BASE}/clinics/${clinic.id}/availability?date=${aWeekOut}`);
    const { slots } = await res.json();
    assert(slots.length > 0, 'the seeded clinic has open slots a week out');

    res = await fetch(`${BASE}/patients/token/${cardToken}/appointments`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        clinicId: clinic.id,
        startsAt: `${aWeekOut} ${slots[0]}`,
        reason: 'CI smoke test',
      }),
    });
    assert(res.status === 201, 'book an appointment');
    const appointment = await res.json();

    res = await fetch(
      `${BASE}/patients/token/${cardToken}/appointments/${appointment.id}/cancel`,
      { method: 'POST' },
    );
    assert(res.status === 200, 'cancel the appointment');

    console.log('\nAll smoke checks passed.');
  } finally {
    proc.kill();
  }
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
