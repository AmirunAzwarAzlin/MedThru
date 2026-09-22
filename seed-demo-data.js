// One-shot demo-data seeder. Populates the local medthru.db with a realistic
// Malaysian clinic roster: doctors, an emergency-response team, and patients
// carrying real-life-shaped records (allergies, medications, conditions,
// vaccinations, lab results, readings, emergency contacts, NFC cards and a
// spread of appointments). Safe to re-run: every insert is guarded by an
// "already seeded?" check keyed on email/phone, so running it twice just
// tops up anything missing rather than duplicating rows.
//
// Run with: node seed-demo-data.js
const db = require('./db');
const { hashPassword } = require('./auth');
const { generateCardToken, hashCardToken, previewOf } = require('./tokens');
const { generateVitalReadings } = require('./vitals-ranges');

const DEMO_PASSWORD = 'Cu5667wja';

function rand(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}
function randInt(min, max) {
  return min + Math.floor(Math.random() * (max - min + 1));
}
function maybe(pct) {
  return Math.random() < pct;
}
function isoDate(d) {
  return d.toISOString().slice(0, 10);
}
function dobForAge(age) {
  const now = new Date();
  const year = now.getFullYear() - age;
  const month = randInt(1, 12);
  const day = randInt(1, 28);
  return `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
}

// --- Doctors (10) + Emergency Response Team (5) -----------------------------

const CLINIC_IDS = db.prepare(`SELECT id FROM clinics ORDER BY id`).all().map((c) => c.id);

const doctors = [
  { name: 'Dr. Ahmad Faiz bin Ismail', email: 'ahmad.faiz@medthru-clinic.test', license: 'MMC-10234', admin: true },
  { name: 'Dr. Siti Nurhaliza binti Abdullah', email: 'siti.nurhaliza@medthru-clinic.test', license: 'MMC-10891' },
  { name: 'Dr. Tan Wei Ming', email: 'tan.weiming@medthru-clinic.test', license: 'MMC-11203' },
  { name: 'Dr. Kavitha a/p Rajendran', email: 'kavitha.rajendran@medthru-clinic.test', license: 'MMC-11477' },
  { name: 'Dr. Muhammad Hafiz bin Rahman', email: 'hafiz.rahman@medthru-clinic.test', license: 'MMC-11832' },
  { name: 'Dr. Lim Chee Keong', email: 'lim.cheekeong@medthru-clinic.test', license: 'MMC-12045' },
  { name: 'Dr. Nurul Ain binti Zainal', email: 'nurul.ain@medthru-clinic.test', license: 'MMC-12390' },
  { name: 'Dr. Rajesh a/l Kumar', email: 'rajesh.kumar@medthru-clinic.test', license: 'MMC-12654' },
  { name: 'Dr. Wong Mei Ling', email: 'wong.meiling@medthru-clinic.test', license: 'MMC-12988' },
  { name: 'Dr. Zulkifli bin Othman', email: 'zulkifli.othman@medthru-clinic.test', license: 'MMC-13217' },
];

const emergencyResponders = [
  { name: 'Amir Hakim bin Salleh (Emergency Response Team)', email: 'amir.hakim@medthru-ems.test', license: 'EMS-8001' },
  { name: 'Nor Aishah binti Yaakob (Emergency Response Team)', email: 'nor.aishah@medthru-ems.test', license: 'EMS-8002' },
  { name: 'Suresh a/l Muniandy (Emergency Response Team)', email: 'suresh.muniandy@medthru-ems.test', license: 'EMS-8003' },
  { name: 'Farah Diyana binti Kamal (Emergency Response Team)', email: 'farah.diyana@medthru-ems.test', license: 'EMS-8004' },
  { name: 'Balasubramaniam a/l Chandran (Emergency Response Team)', email: 'bala.chandran@medthru-ems.test', license: 'EMS-8005' },
];

const findDoctorByEmail = db.prepare(`SELECT id FROM doctors WHERE email = ?`);
const insertDoctor = db.prepare(
  `INSERT INTO doctors (name, license_number, email, password_hash, phone, is_admin, clinic_id)
   VALUES (?, ?, ?, ?, ?, ?, ?)`
);
const promoteAdmin = db.prepare(`UPDATE doctors SET is_admin = 1 WHERE id = ?`);

const doctorIds = [];
const passwordHash = hashPassword(DEMO_PASSWORD);

for (const [i, doc] of doctors.entries()) {
  const existing = findDoctorByEmail.get(doc.email);
  if (existing) {
    doctorIds.push(existing.id);
    if (doc.admin) promoteAdmin.run(existing.id);
    continue;
  }
  const phone = `011-${randInt(2000000, 9999999)}`;
  const clinicId = CLINIC_IDS[i % CLINIC_IDS.length];
  const result = insertDoctor.run(doc.name, doc.license, doc.email, passwordHash, phone, doc.admin ? 1 : 0, clinicId);
  doctorIds.push(Number(result.lastInsertRowid));
}

const emsIds = [];
for (const doc of emergencyResponders) {
  const existing = findDoctorByEmail.get(doc.email);
  if (existing) {
    emsIds.push(existing.id);
    continue;
  }
  const phone = `019-${randInt(2000000, 9999999)}`;
  const result = insertDoctor.run(doc.name, doc.license, doc.email, passwordHash, phone, 0, null);
  emsIds.push(Number(result.lastInsertRowid));
}

console.log(`Doctors ready: ${doctorIds.length} clinic doctors, ${emsIds.length} emergency responders.`);

// --- Patients (50, incl. the required AMIRUN AZWAR BIN AZLIN) --------------

const MALAY_MALE_FIRST = ['Ahmad', 'Muhammad Hafiz', 'Amirul', 'Zulkifli', 'Azman', 'Hakim', 'Faris', 'Iskandar', 'Rizal', 'Syahmi'];
const MALAY_FEMALE_FIRST = ['Nur Aina', 'Siti Fatimah', 'Nurul Izzah', 'Aisyah', 'Farah Diyana', 'Nur Athirah', 'Nabila', 'Nadia', 'Hafsah', 'Zulaikha'];
const MALAY_LAST = ['bin Abdullah', 'bin Ismail', 'bin Kamarudin', 'bin Rahman', 'bin Yusof', 'binti Zainal', 'binti Rosli', 'binti Omar', 'binti Hashim', 'binti Salleh'];

const CHINESE_GIVEN = ['Wei Ming', 'Mei Xin', 'Chee Keong', 'Li Hua', 'Jia Wen', 'Kar Hoe', 'Shu Yi', 'Zhi Hao', 'Yee Wen', 'Boon Kiat'];
const CHINESE_SURNAME = ['Tan', 'Lim', 'Lee', 'Ng', 'Wong', 'Chong', 'Ooi', 'Goh', 'Teh', 'Yap'];

const INDIAN_GIVEN = ['Ramasamy', 'Priya', 'Suresh', 'Kavitha', 'Muthu', 'Divya', 'Sathish', 'Anitha', 'Vignesh', 'Meena'];
const INDIAN_LAST = ['a/l Ramasamy', 'a/p Krishnan', 'a/l Muniandy', 'a/p Rajendran', 'a/l Subramaniam', 'a/p Chandran', 'a/l Kumar', 'a/p Nair'];

function malayName() {
  const female = maybe(0.5);
  const first = rand(female ? MALAY_FEMALE_FIRST : MALAY_MALE_FIRST);
  return { name: `${first} ${rand(MALAY_LAST)}`, gender: female ? 'female' : 'male' };
}
function chineseName() {
  const female = maybe(0.5);
  return { name: `${rand(CHINESE_SURNAME)} ${rand(CHINESE_GIVEN)}`, gender: female ? 'female' : 'male' };
}
function indianName() {
  const female = maybe(0.5);
  return { name: `${rand(INDIAN_GIVEN)} ${rand(INDIAN_LAST)}`, gender: female ? 'female' : 'male' };
}

const BLOOD_TYPES = ['O+', 'O+', 'O+', 'A+', 'A+', 'B+', 'B+', 'AB+', 'O-', 'A-', 'B-', 'AB-'];
const ALLERGENS = [
  { allergen: 'Penicillin', reaction: 'Skin rash and swelling', severity: 'high' },
  { allergen: 'Prawns / shellfish', reaction: 'Hives, lip swelling', severity: 'moderate' },
  { allergen: 'Sulfa drugs', reaction: 'Rash', severity: 'moderate' },
  { allergen: 'Peanuts', reaction: 'Anaphylaxis', severity: 'high' },
  { allergen: 'Dust mites', reaction: 'Sneezing, watery eyes', severity: 'low' },
  { allergen: 'NSAIDs (ibuprofen)', reaction: 'Wheezing', severity: 'moderate' },
  { allergen: 'Eggs', reaction: 'Hives', severity: 'low' },
];
const CONDITIONS = [
  { condition_name: 'Hypertension', body_region: null },
  { condition_name: 'Type 2 Diabetes Mellitus', body_region: null },
  { condition_name: 'Dyslipidaemia', body_region: null },
  { condition_name: 'Bronchial Asthma', body_region: 'chest' },
  { condition_name: 'Allergic Rhinitis', body_region: null },
  { condition_name: 'Gastroesophageal Reflux Disease', body_region: 'chest' },
  { condition_name: 'Gout', body_region: 'leg_l' },
  { condition_name: 'G6PD Deficiency', body_region: null },
  { condition_name: 'Migraine', body_region: 'head' },
  { condition_name: 'Thalassaemia Trait', body_region: null },
];
const MEDICATIONS = [
  { name: 'Metformin', dosage: '500mg', frequency: 'Twice daily' },
  { name: 'Amlodipine', dosage: '5mg', frequency: 'Once daily' },
  { name: 'Simvastatin', dosage: '20mg', frequency: 'Once nightly' },
  { name: 'Losartan', dosage: '50mg', frequency: 'Once daily' },
  { name: 'Salbutamol inhaler', dosage: '100mcg', frequency: 'As needed' },
  { name: 'Omeprazole', dosage: '20mg', frequency: 'Once daily' },
  { name: 'Cetirizine', dosage: '10mg', frequency: 'Once daily' },
  { name: 'Allopurinol', dosage: '100mg', frequency: 'Once daily' },
  { name: 'Gliclazide', dosage: '80mg', frequency: 'Twice daily' },
];
const VACCINES = ['COVID-19 (Pfizer)', 'Influenza', 'Hepatitis B', 'Tetanus (Td)'];
const RELATIONSHIPS = ['Spouse', 'Parent', 'Sibling', 'Child', 'Friend'];

const findPatientByPhone = db.prepare(`SELECT id FROM patients WHERE phone = ?`);
const insertPatient = db.prepare(`
  INSERT INTO patients (
    full_name, date_of_birth, blood_type, gender, phone, password_hash,
    emergency_contact_name, emergency_contact_phone, primary_doctor
  ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
`);
const insertAllergy = db.prepare(`
  INSERT INTO allergies (patient_id, allergen, reaction, severity, doctor_id, source)
  VALUES (?, ?, ?, ?, ?, 'doctor')
`);
const insertMedication = db.prepare(`
  INSERT INTO medications (patient_id, name, dosage, frequency, start_date, doctor_id, source)
  VALUES (?, ?, ?, ?, ?, ?, 'doctor')
`);
const insertCondition = db.prepare(`
  INSERT INTO medical_history (patient_id, condition_name, diagnosed_at, status, body_region, doctor_id, source)
  VALUES (?, ?, ?, 'active', ?, ?, 'doctor')
`);
const insertVaccination = db.prepare(`
  INSERT INTO vaccinations (patient_id, vaccine, dose_number, administered_at, doctor_id, source)
  VALUES (?, ?, ?, ?, ?, 'doctor')
`);
const insertLabResult = db.prepare(`
  INSERT INTO lab_results (patient_id, test_name, value, unit, reference_range, status, taken_at, doctor_id, source)
  VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'doctor')
`);
const insertReading = db.prepare(`
  INSERT INTO readings (patient_id, doctor_id, reading_type, value, unit, source, taken_at)
  VALUES (?, ?, ?, ?, ?, 'patient', ?)
`);
const insertEmergencyContact = db.prepare(`
  INSERT INTO emergency_contacts (patient_id, name, phone, relationship, doctor_id, source)
  VALUES (?, ?, ?, ?, ?, 'doctor')
`);
const insertCard = db.prepare(`
  INSERT INTO cards (patient_id, token_hash, preview, issued_by) VALUES (?, ?, ?, ?)
`);
const insertAudit = db.prepare(`
  INSERT INTO audit_log (patient_id, doctor_id, action, details) VALUES (?, ?, 'create', 'Seeded demo record')
`);

function seedPatientExtras(patientId, doctorId, dob, gender) {
  if (maybe(0.55)) {
    const a = rand(ALLERGENS);
    insertAllergy.run(patientId, a.allergen, a.reaction, a.severity, doctorId);
  }
  const conditionCount = maybe(0.4) ? randInt(1, 2) : 0;
  for (let i = 0; i < conditionCount; i++) {
    const c = rand(CONDITIONS);
    insertCondition.run(patientId, c.condition_name, isoDate(new Date(Date.now() - randInt(30, 1500) * 86400000)), c.body_region, doctorId);
  }
  const medCount = maybe(0.5) ? randInt(1, 2) : 0;
  for (let i = 0; i < medCount; i++) {
    const m = rand(MEDICATIONS);
    insertMedication.run(patientId, m.name, m.dosage, m.frequency, isoDate(new Date(Date.now() - randInt(10, 900) * 86400000)), doctorId);
  }
  if (maybe(0.45)) {
    insertVaccination.run(patientId, rand(VACCINES), randInt(1, 2), isoDate(new Date(Date.now() - randInt(30, 700) * 86400000)), doctorId);
  }
  if (maybe(0.35)) {
    insertLabResult.run(
      patientId, 'Fasting Blood Sugar', (randInt(40, 90) / 10).toFixed(1), 'mmol/L',
      '3.9-6.1', maybe(0.3) ? 'high' : 'normal',
      isoDate(new Date(Date.now() - randInt(1, 200) * 86400000)), doctorId,
    );
  }
  // Every patient gets a full set of vitals + anthropometry, not just some —
  // these are the fields the emergency card view and doctor dashboard expect
  // to always be present.
  const taken = isoDate(new Date(Date.now() - randInt(1, 60) * 86400000));
  for (const reading of generateVitalReadings(dob, gender)) {
    insertReading.run(patientId, doctorId, reading.type, reading.value, reading.unit, taken);
  }
  if (maybe(0.5)) {
    insertReading.run(patientId, doctorId, 'blood_sugar', (randInt(39, 78) / 10).toFixed(1), 'mmol/L', taken);
  }
  if (maybe(0.4)) {
    insertReading.run(patientId, doctorId, 'cholesterol', (randInt(35, 65) / 10).toFixed(1), 'mmol/L', taken);
  }
  if (maybe(0.3)) {
    insertReading.run(patientId, doctorId, 'uric_acid', randInt(150, 450), 'umol/L', taken);
  }
  if (maybe(0.3)) {
    insertEmergencyContact.run(patientId, `${rand(MALAY_MALE_FIRST)} ${rand(MALAY_LAST)}`, `01${randInt(0, 9)}-${randInt(1000000, 9999999)}`, rand(RELATIONSHIPS), doctorId);
  }

  const token = generateCardToken();
  insertCard.run(patientId, hashCardToken(token), previewOf(token), doctorId);
  insertAudit.run(patientId, doctorId);
}

let created = 0;
let usedPhones = new Set(db.prepare(`SELECT phone FROM patients WHERE phone IS NOT NULL`).all().map((r) => r.phone));

function uniquePhone() {
  let phone;
  do {
    phone = `01${randInt(0, 9)}-${randInt(1000000, 9999999)}`;
  } while (usedPhones.has(phone));
  usedPhones.add(phone);
  return phone;
}

const NAME_GENERATORS = [malayName, malayName, malayName, chineseName, chineseName, indianName];

for (let i = 0; i < 49; i++) {
  const { name, gender } = rand(NAME_GENERATORS)();
  const age = randInt(4, 82);
  const dob = dobForAge(age);
  const doctorName = doctors[randInt(0, doctors.length - 1)].name;
  const phone = uniquePhone();
  if (findPatientByPhone.get(phone)) continue;

  const result = insertPatient.run(
    name,
    dob,
    rand(BLOOD_TYPES),
    gender,
    phone,
    null, // no phone-login password for the bulk of the roster
    null, null,
    doctorName,
  );
  const patientId = Number(result.lastInsertRowid);
  seedPatientExtras(patientId, rand(doctorIds), dob, gender);
  created += 1;
}

// --- The required named patient: AMIRUN AZWAR BIN AZLIN ---------------------

const REQUIRED_PHONE = '01157785382';
let amirun = findPatientByPhone.get(REQUIRED_PHONE);
if (!amirun) {
  const amirunDob = dobForAge(27);
  const result = insertPatient.run(
    'Amirun Azwar bin Azlin',
    amirunDob,
    'O+',
    'male',
    REQUIRED_PHONE,
    hashPassword(DEMO_PASSWORD),
    'Azlin bin Yusof', '019-2233445',
    'Dr. Ahmad Faiz bin Ismail',
  );
  amirun = { id: Number(result.lastInsertRowid) };
  seedPatientExtras(amirun.id, doctorIds[0], amirunDob, 'male');
  console.log(`Created patient "Amirun Azwar bin Azlin" (id ${amirun.id}) — phone ${REQUIRED_PHONE}.`);
} else {
  // Existing row (e.g. re-run): make sure the phone-login password is set.
  db.prepare(`UPDATE patients SET password_hash = ? WHERE id = ?`).run(hashPassword(DEMO_PASSWORD), amirun.id);
  console.log(`Patient "Amirun Azwar bin Azlin" already present (id ${amirun.id}) — password refreshed.`);
}

console.log(`Patients ready: ${created} newly created (plus the named record above).`);

// --- Appointments: a realistic spread across clinics, doctors and statuses -

const allPatientIds = db.prepare(`SELECT id FROM patients`).all().map((p) => p.id);
const STATUS_WEIGHTS = [
  ['completed', 8], ['confirmed', 4], ['requested', 3],
  ['cancelled', 2], ['rejected', 1], ['reschedule_requested', 2],
];
function weightedStatus() {
  const total = STATUS_WEIGHTS.reduce((s, [, w]) => s + w, 0);
  let r = Math.random() * total;
  for (const [status, w] of STATUS_WEIGHTS) {
    if (r < w) return status;
    r -= w;
  }
  return 'requested';
}
const REASONS = [
  'Follow-up consultation', 'Fever and cough', 'Routine health screening',
  'Diabetes review', 'Blood pressure check', 'Vaccination',
  'Skin rash', 'Annual physical exam', 'Medication refill', 'Joint pain',
];

const insertAppointment = db.prepare(`
  INSERT INTO appointments (
    patient_id, clinic_id, doctor_id, starts_at, slot_minutes, reason,
    status, decided_by, decided_at
  ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
`);

const existingApptCount = db.prepare(`SELECT COUNT(*) AS n FROM appointments`).get().n;
let apptsCreated = 0;
if (existingApptCount < 40) {
  const usedSlots = new Set();
  let attempts = 0;
  while (apptsCreated < 35 && attempts < 500) {
    attempts += 1;
    const patientId = rand(allPatientIds);
    const doctorId = rand(doctorIds);
    const clinicId = CLINIC_IDS[doctorIds.indexOf(doctorId) % CLINIC_IDS.length];
    const dayOffset = randInt(-20, 10); // spread across last ~3 weeks and next ~10 days
    const day = new Date(Date.now() + dayOffset * 86400000);
    const hour = randInt(9, 16);
    const minute = rand([0, 15, 30, 45]);
    const startsAt = `${isoDate(day)} ${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`;
    const slotKey = `${clinicId}|${doctorId}|${startsAt}`;
    if (usedSlots.has(slotKey)) continue;
    usedSlots.add(slotKey);

    let status = weightedStatus();
    // Only appointments in the future make sense as still-pending.
    const isFuture = dayOffset >= 0;
    if (!isFuture && (status === 'requested' || status === 'reschedule_requested')) status = 'completed';
    if (isFuture && status === 'completed') status = 'confirmed';

    const decided = ['confirmed', 'completed', 'rejected', 'cancelled'].includes(status);
    try {
      insertAppointment.run(
        patientId, clinicId, doctorId, startsAt, 30, rand(REASONS),
        status, decided ? doctorId : null, decided ? startsAt : null,
      );
      apptsCreated += 1;
    } catch {
      // Unique-slot constraint collision with a pre-existing row — skip.
    }
  }
}
console.log(`Appointments ready: ${apptsCreated} newly created (${existingApptCount} already existed).`);

console.log('\nDone. Demo logins (all use password: ' + DEMO_PASSWORD + '):');
console.log('  Doctor (admin):     ahmad.faiz@medthru-clinic.test');
console.log('  Emergency response: amir.hakim@medthru-ems.test');
console.log('  Patient (phone):    01157785382  (Amirun Azwar bin Azlin)');
