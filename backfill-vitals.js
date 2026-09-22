// One-off repair pass for patients created before the seeder guaranteed full
// vitals + anthropometry (and before the reading_type naming bug was fixed).
// Safe to re-run: it only fills in reading types a patient is missing, never
// duplicates.
//
// Run with: node backfill-vitals.js
const db = require('./db');
const { generateVitalReadings } = require('./vitals-ranges');

// Earlier seed runs wrote these under the wrong key, so the app's
// READING_TYPES lookup (which expects the blood_pressure_* names) never
// saw them. Rename in place rather than leaving orphaned rows behind.
const RENAMES = { bp_systolic: 'blood_pressure_systolic', bp_diastolic: 'blood_pressure_diastolic' };
const renameType = db.prepare(`UPDATE readings SET reading_type = ? WHERE reading_type = ?`);
for (const [oldType, newType] of Object.entries(RENAMES)) {
  const result = renameType.run(newType, oldType);
  if (result.changes) console.log(`Renamed ${result.changes} '${oldType}' reading(s) to '${newType}'.`);
}

const VITAL_TYPES = ['blood_pressure_systolic', 'blood_pressure_diastolic', 'heart_rate', 'temperature', 'weight', 'height'];

const patients = db.prepare(`SELECT id, date_of_birth, gender, primary_doctor FROM patients`).all();
const findDoctorByName = db.prepare(`SELECT id FROM doctors WHERE name = ?`);
const anyDoctorId = db.prepare(`SELECT id FROM doctors ORDER BY id LIMIT 1`).get()?.id ?? null;
const existingTypesFor = db.prepare(
  `SELECT DISTINCT reading_type FROM readings WHERE patient_id = ? AND reading_type IN (${VITAL_TYPES.map(() => '?').join(',')})`
);
const insertReading = db.prepare(`
  INSERT INTO readings (patient_id, doctor_id, reading_type, value, unit, source, taken_at)
  VALUES (?, ?, ?, ?, ?, 'patient', ?)
`);

let patientsUpdated = 0;
let readingsInserted = 0;

for (const patient of patients) {
  const present = new Set(existingTypesFor.all(patient.id, ...VITAL_TYPES).map((r) => r.reading_type));
  const missing = VITAL_TYPES.filter((t) => !present.has(t));
  if (missing.length === 0) continue;

  const doctorId = (patient.primary_doctor && findDoctorByName.get(patient.primary_doctor)?.id) || anyDoctorId;
  const taken = new Date().toISOString().slice(0, 10);
  const readings = generateVitalReadings(patient.date_of_birth, patient.gender)
    .filter((r) => missing.includes(r.type));

  for (const reading of readings) {
    insertReading.run(patient.id, doctorId, reading.type, reading.value, reading.unit, taken);
    readingsInserted += 1;
  }
  patientsUpdated += 1;
}

console.log(`Backfilled ${readingsInserted} reading(s) across ${patientsUpdated} patient(s) (${patients.length} total patients checked).`);
