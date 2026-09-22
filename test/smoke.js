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

    // A doctorId must actually belong to the clinic being booked, and must
    // actually exist.
    const otherClinic = clinics.find((c) => c.id !== clinic.id);
    res = await fetch(`${BASE}/patients/token/${cardToken}/appointments`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        clinicId: otherClinic.id, doctorId: doctorA.id,
        startsAt: `${aWeekOut} ${pickedSlot}`, reason: 'Wrong-clinic doctorId',
      }),
    });
    assert(res.status === 400, 'booking rejects a doctorId from a different clinic');

    res = await fetch(`${BASE}/patients/token/${cardToken}/appointments`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        clinicId: clinic.id, doctorId: 999999,
        startsAt: `${aWeekOut} ${pickedSlot}`, reason: 'Nonexistent doctorId',
      }),
    });
    assert(res.status === 400, 'booking rejects a doctorId that does not exist');

    // The mirror image of the doctor-B regression above: two doctors sharing a
    // time is fine, but a doctor and a *doctor-less* appointment sharing one is
    // not — that is one clinic being in two places at once. Neither partial
    // unique index sees across the doctor_id IS NULL / IS NOT NULL divide, so
    // this is caught in the handler; without that check it succeeds silently
    // and deterministically, no race required.
    // Taken from the end of the day so the reschedule assertions further down,
    // which all reach for the earliest free slot, aren't starved by these two.
    res = await fetch(`${BASE}/clinics/${clinic.id}/availability?date=${aWeekOut}`);
    const { slots: clinicWideSlots } = await res.json();
    const unassignedFirstSlot = clinicWideSlots[clinicWideSlots.length - 1];
    const doctorFirstSlot = clinicWideSlots[clinicWideSlots.length - 2];
    assert(unassignedFirstSlot && doctorFirstSlot && unassignedFirstSlot !== doctorFirstSlot,
      'two clinic-wide free slots are available for the cross-category tests');

    res = await fetch(`${BASE}/patients/token/${cardToken}/appointments`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        clinicId: clinic.id,
        startsAt: `${aWeekOut} ${unassignedFirstSlot}`, reason: 'Unassigned booking holds the clinic slot',
      }),
    });
    assert(res.status === 201, 'an appointment can be booked with no doctor assigned');

    res = await fetch(`${BASE}/clinics/${clinic.id}/availability?date=${aWeekOut}&doctorId=${doctorA.id}`);
    const { slots: doctorASlotsVsUnassigned } = await res.json();
    assert(!doctorASlotsVsUnassigned.includes(unassignedFirstSlot),
      "a doctor's availability hides a slot held by an unassigned appointment");

    res = await fetch(`${BASE}/patients/token/${cardToken}/appointments`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        clinicId: clinic.id, doctorId: doctorA.id,
        startsAt: `${aWeekOut} ${unassignedFirstSlot}`, reason: 'Doctor booking over an unassigned slot',
      }),
    });
    assert(res.status === 409,
      'booking a doctor onto a slot an unassigned appointment holds is rejected');

    // And the reverse direction: doctor-assigned first, unassigned second.
    res = await fetch(`${BASE}/patients/token/${cardToken}/appointments`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        clinicId: clinic.id, doctorId: doctorA.id,
        startsAt: `${aWeekOut} ${doctorFirstSlot}`, reason: 'Doctor-assigned booking holds the clinic slot',
      }),
    });
    assert(res.status === 201, 'a doctor-assigned appointment books the second free slot');

    res = await fetch(`${BASE}/patients/token/${cardToken}/appointments`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        clinicId: clinic.id,
        startsAt: `${aWeekOut} ${doctorFirstSlot}`, reason: 'Unassigned booking over a doctor slot',
      }),
    });
    assert(res.status === 409,
      'booking an unassigned appointment onto a slot a doctor holds is rejected');

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

    // --- Contraindication engine: check + override ---
    res = await fetch(`${BASE}/patients/token/${cardToken}/contraindication-check`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ treatmentType: 'medication', treatmentName: 'Amoxicillin' }),
    });
    assert(res.status === 200, 'contraindication check succeeds');
    const amoxCheck = await res.json();
    assert(amoxCheck.hardStops.length > 0, 'amoxicillin is flagged for a patient with a logged penicillin allergy');
    assert(amoxCheck.hardStops[0].reason.length > 0, 'the hard stop carries a human-readable reason');
    assert(amoxCheck.aiFlag === null, 'the AI layer is skipped once a hard stop already fired');

    res = await fetch(`${BASE}/patients/token/${cardToken}/contraindication-check`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ treatmentType: 'medication', treatmentName: 'Paracetamol' }),
    });
    assert(res.status === 200, 'contraindication check succeeds for an unrelated medication');
    const clearCheck = await res.json();
    assert(clearCheck.hardStops.length === 0, 'paracetamol is not flagged for this patient');
    assert(clearCheck.aiFlag === null, 'no GEMINI_API_KEY is configured in CI, so the AI layer stays null rather than erroring');

    // An expired medication (end_date in the past) must not count as "active"
    // for the hard-stop rule table — otherwise a long-discontinued drug could
    // wrongly block (or fail to block) a new prescription forever.
    res = await fetch(`${BASE}/patients/token/${cardToken}/medications`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ name: 'Warfarin', dosage: '5mg', endDate: '2020-01-01' }),
    });
    assert(res.status === 201, 'add an expired medication for the CI Patient');

    res = await fetch(`${BASE}/patients/token/${cardToken}/contraindication-check`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ treatmentType: 'medication', treatmentName: 'Ibuprofen' }),
    });
    assert(res.status === 200, 'contraindication check succeeds for the warfarin/NSAID probe');
    const expiredMedCheck = await res.json();
    assert(expiredMedCheck.hardStops.length === 0,
      'an expired warfarin prescription does not trigger the warfarin/NSAID hard stop');

    res = await fetch(`${BASE}/patients/token/${cardToken}/contraindication-check`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ treatmentType: 'medication', treatmentName: 'Amoxicillin' }),
    });
    assert(res.status === 401, 'the contraindication check requires a doctor bearer token');

    res = await fetch(`${BASE}/patients/token/${cardToken}/contraindication-override`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({
        ruleIds: amoxCheck.hardStops.map((h) => h.ruleId),
        reason: 'Desensitization protocol already in place; proceeding under supervision.',
        treatmentName: 'Amoxicillin',
      }),
    });
    assert(res.status === 201, 'a doctor can log an override for a hard-stopped treatment');

    res = await fetch(`${BASE}/patients/${patient.id}/audit`, { headers: { Authorization: `Bearer ${token}` } });
    const auditEntries = await res.json();
    assert(auditEntries.some((a) => a.action === 'contraindication_override'),
      'the override is written to the audit log');
    assert(auditEntries.some((a) => a.action === 'contraindication_flagged'),
      'the flagged check itself is also written to the audit log');

    // --- Contraindication engine: admin-only rule CRUD ---
    res = await fetch(`${BASE}/contraindication-rules`, { headers: { Authorization: `Bearer ${token}` } });
    assert(res.status === 200, 'any doctor can list contraindication rules');
    const seededRules = await res.json();
    assert(seededRules.length >= 15, 'the starter rule set is seeded on first boot');

    res = await fetch(`${BASE}/contraindication-rules`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({
        ruleType: 'medication',
        triggerTerms: 'test-trigger',
        treatmentTerms: 'test-treatment',
        severity: 'moderate',
        reason: 'CI test rule.',
      }),
    });
    assert(res.status === 403, 'a non-admin doctor cannot create a contraindication rule');

    // Promote CI Doctor to admin directly — no API surface for this, same
    // direct-DB approach already used earlier in this file for the doctor
    // per-clinic index test.
    {
      const { DatabaseSync } = require('node:sqlite');
      const promoteDb = new DatabaseSync(DB_PATH);
      promoteDb.prepare(`UPDATE doctors SET is_admin = 1 WHERE email = ?`).run('ci@medthru.test');
      promoteDb.close();
    }

    res = await fetch(`${BASE}/contraindication-rules`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({
        ruleType: 'medication',
        triggerTerms: 'test-trigger',
        treatmentTerms: 'test-treatment',
        severity: 'moderate',
        reason: 'CI test rule.',
      }),
    });
    assert(res.status === 201, 'an admin doctor can create a contraindication rule');
    const newRule = await res.json();

    res = await fetch(`${BASE}/contraindication-rules/${newRule.id}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({
        ruleType: 'medication',
        triggerTerms: 'test-trigger',
        treatmentTerms: 'test-treatment-edited',
        severity: 'high',
        reason: 'CI test rule, edited.',
      }),
    });
    assert(res.status === 200, 'an admin doctor can edit a contraindication rule');
    const editedRule = await res.json();
    assert(editedRule.treatment_terms === 'test-treatment-edited', 'the edit is reflected in the response');

    res = await fetch(`${BASE}/contraindication-rules/${newRule.id}`, {
      method: 'DELETE',
      headers: { Authorization: `Bearer ${token}` },
    });
    assert(res.status === 200, 'an admin doctor can delete a contraindication rule');

    console.log('\nAll smoke checks passed.');
  } finally {
    proc.kill();
  }
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
