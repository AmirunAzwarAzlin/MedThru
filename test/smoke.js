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

    // Test the index split behavior: two different doctors at the same clinic
    // can both hold appointments at the same time, but the same doctor cannot.
    // This requires direct database inserts since the API doesn't yet support
    // assigning doctors to appointments (Task 2/3).
    {
      const testDb = new DatabaseSync(DB_PATH);

      // Get a seeded clinic and insert test doctors.
      const clinic = testDb.prepare(`SELECT id FROM clinics LIMIT 1`).get();
      assert(clinic, 'clinic exists to test against');

      const insertDoctor = testDb.prepare(
        `INSERT INTO doctors (name, license_number, email, password_hash)
         VALUES (?, ?, ?, ?)`
      );
      const doctor1Id = insertDoctor.run('Test Doctor 1', 'TEST-001', 'test1@medthru.test', 'hash1').lastInsertRowid;
      const doctor2Id = insertDoctor.run('Test Doctor 2', 'TEST-002', 'test2@medthru.test', 'hash2').lastInsertRowid;

      // Insert a test patient.
      const insertPatient = testDb.prepare(
        `INSERT INTO patients (full_name) VALUES (?)`
      );
      const patientId = insertPatient.run('Test Patient').lastInsertRowid;

      const testTime = '2099-12-25 10:00';
      const insertAppointment = testDb.prepare(
        `INSERT INTO appointments (patient_id, clinic_id, doctor_id, starts_at, slot_minutes, status)
         VALUES (?, ?, ?, ?, 30, 'confirmed')`
      );

      // First doctor can book the slot.
      insertAppointment.run(patientId, clinic.id, doctor1Id, testTime);
      assert(true, 'doctor 1 can hold an appointment at clinic+time');

      // Second doctor can also book the same slot (per-doctor index allows it).
      insertAppointment.run(patientId, clinic.id, doctor2Id, testTime);
      assert(true, 'doctor 2 can hold an appointment at the same clinic+time (per-doctor index allows it)');

      // First doctor cannot book the same slot again (unique per-doctor index prevents it).
      let secondBookingThrew = false;
      try {
        insertAppointment.run(patientId, clinic.id, doctor1Id, testTime);
      } catch (err) {
        if (err.message.includes('UNIQUE constraint failed')) {
          secondBookingThrew = true;
        }
      }
      assert(secondBookingThrew, 'doctor 1 cannot hold a second appointment at the same clinic+time (per-doctor index prevents it)');

      testDb.close();
    }

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

    // Pick a clinic open every day of the week for use throughout the rest of
    // the test. Later tasks (3, 6, 7) need this in scope too.
    res = await fetch(`${BASE}/clinics`);
    const clinics = await res.json();
    assert(clinics.length > 0, 'clinics are seeded on first boot');
    const clinic = clinics.find((c) => c.open_days === '1,2,3,4,5,6,7');
    assert(clinic, 'a clinic open every day exists to book against');

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

    // Appointments: book and cancel.
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

    console.log('\nAll smoke checks passed.');
  } finally {
    proc.kill();
  }
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
