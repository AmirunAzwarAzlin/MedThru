const { DatabaseSync } = require('node:sqlite');
const path = require('node:path');
const { hashCardToken, previewOf } = require('./tokens');

const db = new DatabaseSync(path.join(__dirname, 'medthru.db'));

db.exec(`
  CREATE TABLE IF NOT EXISTS patients (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    full_name TEXT NOT NULL,
    date_of_birth TEXT,
    blood_type TEXT,
    allergies TEXT,
    medications TEXT,
    conditions TEXT,
    emergency_contact_name TEXT,
    emergency_contact_phone TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
  );

  CREATE TABLE IF NOT EXISTS doctors (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    license_number TEXT UNIQUE NOT NULL,
    email TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );

  -- One row per physical card ever issued. Only the SHA-256 hash of the token
  -- is stored, so a leaked database does not expose anyone's card. Revoking a
  -- lost card is a status flip; reissuing adds a new row. The patient record
  -- itself never moves.
  CREATE TABLE IF NOT EXISTS cards (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id INTEGER NOT NULL REFERENCES patients(id),
    token_hash TEXT UNIQUE NOT NULL,
    preview TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    issued_by INTEGER REFERENCES doctors(id),
    revoked_by INTEGER REFERENCES doctors(id),
    issued_at TEXT NOT NULL DEFAULT (datetime('now')),
    revoked_at TEXT
  );

  CREATE INDEX IF NOT EXISTS idx_cards_lookup ON cards(token_hash, status);

  CREATE TABLE IF NOT EXISTS audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id INTEGER NOT NULL REFERENCES patients(id),
    doctor_id INTEGER REFERENCES doctors(id),
    action TEXT NOT NULL,
    details TEXT,
    timestamp TEXT NOT NULL DEFAULT (datetime('now'))
  );

  -- Append-only timeline of clinical updates (checkups, med changes, etc.).
  -- Entries are never overwritten, preserving the patient's history.
  CREATE TABLE IF NOT EXISTS clinical_notes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id INTEGER NOT NULL REFERENCES patients(id),
    doctor_id INTEGER REFERENCES doctors(id),
    note_type TEXT NOT NULL,
    body TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );

  -- Self-measured vitals (blood sugar, cholesterol, uric acid). Kept apart
  -- from clinical_notes on purpose: the source column records whether the
  -- patient or a doctor entered it, so self-reported values are never
  -- mistaken for clinician-verified clinical data.
  CREATE TABLE IF NOT EXISTS readings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id INTEGER NOT NULL REFERENCES patients(id),
    doctor_id INTEGER REFERENCES doctors(id),
    reading_type TEXT NOT NULL,
    value REAL NOT NULL,
    unit TEXT NOT NULL,
    note TEXT,
    source TEXT NOT NULL DEFAULT 'patient',
    taken_at TEXT NOT NULL DEFAULT (datetime('now')),
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );

  CREATE INDEX IF NOT EXISTS idx_readings_patient
    ON readings(patient_id, reading_type, taken_at DESC);

  -- Health records: structured, dated entries a patient or doctor can add,
  -- one table per category since their fields genuinely differ. Each follows
  -- the same source/doctor_id bookkeeping as readings, so a self-report is
  -- never confused with a clinician-entered one.
  CREATE TABLE IF NOT EXISTS allergies (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id INTEGER NOT NULL REFERENCES patients(id),
    allergen TEXT NOT NULL,
    reaction TEXT,
    severity TEXT,
    note TEXT,
    doctor_id INTEGER REFERENCES doctors(id),
    source TEXT NOT NULL DEFAULT 'patient',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE INDEX IF NOT EXISTS idx_allergies_patient ON allergies(patient_id, created_at DESC);

  CREATE TABLE IF NOT EXISTS medications (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id INTEGER NOT NULL REFERENCES patients(id),
    name TEXT NOT NULL,
    dosage TEXT,
    frequency TEXT,
    start_date TEXT,
    end_date TEXT,
    note TEXT,
    doctor_id INTEGER REFERENCES doctors(id),
    source TEXT NOT NULL DEFAULT 'patient',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE INDEX IF NOT EXISTS idx_medications_patient ON medications(patient_id, created_at DESC);

  CREATE TABLE IF NOT EXISTS vaccinations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id INTEGER NOT NULL REFERENCES patients(id),
    vaccine TEXT NOT NULL,
    dose_number INTEGER,
    administered_at TEXT NOT NULL,
    -- Optional date the next dose is due, for immunization scheduling.
    next_due TEXT,
    note TEXT,
    doctor_id INTEGER REFERENCES doctors(id),
    source TEXT NOT NULL DEFAULT 'patient',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE INDEX IF NOT EXISTS idx_vaccinations_patient ON vaccinations(patient_id, administered_at DESC);

  CREATE TABLE IF NOT EXISTS medical_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id INTEGER NOT NULL REFERENCES patients(id),
    condition_name TEXT NOT NULL,
    diagnosed_at TEXT,
    status TEXT NOT NULL DEFAULT 'active',
    note TEXT,
    -- Optional anatomical tag (e.g. 'chest', 'leg_l') so the emergency body
    -- map can locate a condition on the figure. Null for untagged/systemic.
    body_region TEXT,
    doctor_id INTEGER REFERENCES doctors(id),
    source TEXT NOT NULL DEFAULT 'patient',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE INDEX IF NOT EXISTS idx_medical_history_patient ON medical_history(patient_id, created_at DESC);

  -- Multiple emergency contacts per patient (spouse, parent, etc.), replacing
  -- the single emergency_contact_name/phone pair with a proper list. That
  -- legacy pair stays on patients as a fallback for older records.
  CREATE TABLE IF NOT EXISTS emergency_contacts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id INTEGER NOT NULL REFERENCES patients(id),
    name TEXT NOT NULL,
    phone TEXT NOT NULL,
    relationship TEXT,
    note TEXT,
    doctor_id INTEGER REFERENCES doctors(id),
    source TEXT NOT NULL DEFAULT 'patient',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE INDEX IF NOT EXISTS idx_emergency_contacts_patient ON emergency_contacts(patient_id, created_at DESC);

  -- Lab / test results: a single measured value with its unit, the lab's
  -- reference range, and a status flag so an out-of-range figure stands out.
  CREATE TABLE IF NOT EXISTS lab_results (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id INTEGER NOT NULL REFERENCES patients(id),
    test_name TEXT NOT NULL,
    value TEXT,
    unit TEXT,
    reference_range TEXT,
    status TEXT NOT NULL DEFAULT 'normal',
    taken_at TEXT,
    note TEXT,
    doctor_id INTEGER REFERENCES doctors(id),
    source TEXT NOT NULL DEFAULT 'patient',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE INDEX IF NOT EXISTS idx_lab_results_patient ON lab_results(patient_id, taken_at DESC);

  -- Uploaded documents (scans, referral letters, X-rays). The bytes live on
  -- disk under uploads/<stored_name>; only metadata is kept here.
  CREATE TABLE IF NOT EXISTS documents (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id INTEGER NOT NULL REFERENCES patients(id),
    filename TEXT NOT NULL,
    mime_type TEXT,
    size_bytes INTEGER,
    stored_name TEXT NOT NULL,
    doctor_id INTEGER REFERENCES doctors(id),
    source TEXT NOT NULL DEFAULT 'patient',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE INDEX IF NOT EXISTS idx_documents_patient ON documents(patient_id, created_at DESC);

  -- A per-patient message thread shared between the patient (via their card)
  -- and any doctor viewing their record. Not clinical data, but server-side so
  -- both sides see the same conversation.
  CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id INTEGER NOT NULL REFERENCES patients(id),
    sender TEXT NOT NULL,               -- 'patient' | 'doctor'
    doctor_id INTEGER REFERENCES doctors(id),
    body TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );
  CREATE INDEX IF NOT EXISTS idx_messages_patient ON messages(patient_id, created_at ASC);

  -- Hospitals and clinics a patient can book into. Opening hours plus a slot
  -- length are enough to generate the bookable times for any date, so there is
  -- no need to store a row per empty slot.
  CREATE TABLE IF NOT EXISTS clinics (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    kind TEXT NOT NULL DEFAULT 'clinic',
    address TEXT,
    phone TEXT,
    opens_at TEXT NOT NULL DEFAULT '09:00',
    closes_at TEXT NOT NULL DEFAULT '17:00',
    slot_minutes INTEGER NOT NULL DEFAULT 30,
    -- ISO weekdays the clinic runs: 1 = Monday … 7 = Sunday.
    open_days TEXT NOT NULL DEFAULT '1,2,3,4,5',
    status TEXT NOT NULL DEFAULT 'active',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );

  -- starts_at is clinic-local wall clock ('YYYY-MM-DD HH:MM'), not UTC: it is
  -- the time printed on the appointment slip.
  CREATE TABLE IF NOT EXISTS appointments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    patient_id INTEGER NOT NULL REFERENCES patients(id),
    clinic_id INTEGER NOT NULL REFERENCES clinics(id),
    starts_at TEXT NOT NULL,
    slot_minutes INTEGER NOT NULL,
    reason TEXT,
    status TEXT NOT NULL DEFAULT 'requested',
    decided_by INTEGER REFERENCES doctors(id),
    decided_at TEXT,
    decision_note TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
  );

  -- The one rule that actually prevents a double booking. Two patients can
  -- both be looking at the same free slot and both pass an availability check,
  -- so the database, not the request handler, has the final say: the second
  -- INSERT loses and is reported as a conflict.
  --
  -- Partial on purpose. It covers only the statuses that occupy the slot, so a
  -- pending request still blocks the time (a doctor has yet to rule on it),
  -- while cancelling or rejecting releases it with no extra bookkeeping — and
  -- a slot can be re-booked after a cancellation without tripping the index.
  CREATE UNIQUE INDEX IF NOT EXISTS idx_appointments_slot
    ON appointments(clinic_id, starts_at)
    WHERE status IN ('requested', 'confirmed');

  CREATE INDEX IF NOT EXISTS idx_appointments_patient
    ON appointments(patient_id, starts_at DESC);

  CREATE INDEX IF NOT EXISTS idx_appointments_queue
    ON appointments(status, starts_at);
`);

// --- Seed: a few registered facilities so booking works on a fresh database ---
{
  const { n } = db.prepare(`SELECT COUNT(*) AS n FROM clinics`).get();
  if (n === 0) {
    const insert = db.prepare(
      `INSERT INTO clinics (name, kind, address, phone, opens_at, closes_at, slot_minutes, open_days)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
    );
    const seed = [
      ['Hospital Kuala Lumpur', 'hospital', 'Jalan Pahang, 50586 Kuala Lumpur',
        '03-2615 5555', '08:00', '17:00', 30, '1,2,3,4,5'],
      ['Klinik Kesihatan Bangsar', 'clinic', 'Jalan Maarof, 59000 Kuala Lumpur',
        '03-2282 1534', '08:00', '16:30', 20, '1,2,3,4,5,6'],
      ['Hospital Selayang', 'hospital', 'Lebuhraya Selayang-Kepong, 68100 Batu Caves',
        '03-6126 3333', '08:30', '16:30', 30, '1,2,3,4,5'],
      ['Klinik Mediviron USJ', 'clinic', 'USJ 10, 47620 Subang Jaya',
        '03-8024 4088', '09:00', '18:00', 15, '1,2,3,4,5,6,7'],
    ];
    for (const row of seed) insert.run(...row);
    console.log(`Seeded ${seed.length} clinics and hospitals.`);
  }
}

function patientColumns() {
  return db.prepare(`PRAGMA table_info(patients)`).all().map((c) => c.name);
}

function doctorColumns() {
  return db.prepare(`PRAGMA table_info(doctors)`).all().map((c) => c.name);
}

// --- Migration: doctor phone number ---
{
  if (!doctorColumns().includes('phone')) {
    db.exec(`ALTER TABLE doctors ADD COLUMN phone TEXT`);
  }
}

// --- Migration: administrator flag ---
//
// Card reissue/revoke and deleting a patient record outright are
// administrator-only actions, not something every doctor account can do.
// If no administrator exists yet (fresh install, or the flag just got
// added), promote the earliest-registered doctor — otherwise those actions
// would be permanently unreachable by anyone.
{
  if (!doctorColumns().includes('is_admin')) {
    db.exec(`ALTER TABLE doctors ADD COLUMN is_admin INTEGER NOT NULL DEFAULT 0`);
  }
  const { n } = db.prepare(`SELECT COUNT(*) AS n FROM doctors WHERE is_admin = 1`).get();
  if (n === 0) {
    const first = db.prepare(`SELECT id, name FROM doctors ORDER BY id LIMIT 1`).get();
    if (first) {
      db.prepare(`UPDATE doctors SET is_admin = 1 WHERE id = ?`).run(first.id);
      console.log(`No administrator found — promoted "${first.name}" (doctor #${first.id}) to administrator.`);
    }
  }
}

// --- Migration: patient phone/password login, as an alternative to the
// physical card. Both columns stay null until a patient opts in while
// holding their card, so existing records are unaffected. ---
{
  const cols = patientColumns();
  if (!cols.includes('phone')) {
    db.exec(`ALTER TABLE patients ADD COLUMN phone TEXT`);
  }
  if (!cols.includes('password_hash')) {
    db.exec(`ALTER TABLE patients ADD COLUMN password_hash TEXT`);
  }
  db.exec(`CREATE UNIQUE INDEX IF NOT EXISTS idx_patients_phone ON patients(phone) WHERE phone IS NOT NULL`);
}

// --- Migration 1: structured care-plan columns ---
{
  const cols = patientColumns();
  const added = {
    next_appointment: 'TEXT',
    surgery_date: 'TEXT',
    primary_doctor: 'TEXT',
    // Optional demographic ('female' | 'male' | other free text). Feeds the
    // doctor dashboard's demographics breakdown; older rows stay null.
    gender: 'TEXT',
  };
  for (const [name, type] of Object.entries(added)) {
    if (!cols.includes(name)) {
      db.exec(`ALTER TABLE patients ADD COLUMN ${name} ${type}`);
    }
  }
}

// --- Migration: anatomical tagging for medical history ---
//
// Lets a condition be pinned to a body region so the emergency body map can
// show where it is. Older rows stay null (untagged/systemic), so nothing
// existing is disturbed.
{
  const cols = db.prepare(`PRAGMA table_info(medical_history)`).all().map((c) => c.name);
  if (!cols.includes('body_region')) {
    db.exec(`ALTER TABLE medical_history ADD COLUMN body_region TEXT`);
  }
}

// --- Migration: immunization scheduling ---
//
// Adds an optional next-due date to vaccinations so the record can flag an
// upcoming or overdue dose. Older rows stay null.
{
  const cols = db.prepare(`PRAGMA table_info(vaccinations)`).all().map((c) => c.name);
  if (!cols.includes('next_due')) {
    db.exec(`ALTER TABLE vaccinations ADD COLUMN next_due TEXT`);
  }
}

// --- Migration 2: plaintext patients.token -> hashed cards table ---
//
// Older databases stored the card token in the clear on the patient row. Move
// each one into `cards` as a hash, then rebuild `patients` without the column
// so the plaintext value is gone for good.
if (patientColumns().includes('token')) {
  const rows = db.prepare(`SELECT id, token FROM patients`).all();

  const insertCard = db.prepare(
    `INSERT OR IGNORE INTO cards (patient_id, token_hash, preview, status)
     VALUES (?, ?, ?, 'active')`
  );
  for (const { id, token } of rows) {
    insertCard.run(id, hashCardToken(token), previewOf(token));
  }

  // SQLite cannot drop a UNIQUE column in place: rebuild the table. Other
  // tables carry foreign keys into patients(id), so enforcement must be off
  // while the old table is swapped out. This is the procedure SQLite itself
  // documents for altering a table. The pragma is a no-op inside a
  // transaction, hence the separate exec calls.
  db.exec(`PRAGMA foreign_keys = OFF`);
  db.exec(`DROP TABLE IF EXISTS patients_new`);
  db.exec(`
    CREATE TABLE patients_new (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      full_name TEXT NOT NULL,
      date_of_birth TEXT,
      blood_type TEXT,
      allergies TEXT,
      medications TEXT,
      conditions TEXT,
      emergency_contact_name TEXT,
      emergency_contact_phone TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now')),
      next_appointment TEXT,
      surgery_date TEXT,
      primary_doctor TEXT
    );

    INSERT INTO patients_new (
      id, full_name, date_of_birth, blood_type, allergies, medications,
      conditions, emergency_contact_name, emergency_contact_phone,
      created_at, updated_at, next_appointment, surgery_date, primary_doctor
    )
    SELECT
      id, full_name, date_of_birth, blood_type, allergies, medications,
      conditions, emergency_contact_name, emergency_contact_phone,
      created_at, updated_at, next_appointment, surgery_date, primary_doctor
    FROM patients;

    DROP TABLE patients;
    ALTER TABLE patients_new RENAME TO patients;
  `);
  db.exec(`PRAGMA foreign_keys = ON`);

  const check = db.prepare(`PRAGMA foreign_key_check`).all();
  if (check.length > 0) {
    throw new Error(
      `Migration left ${check.length} dangling foreign key(s); aborting.`
    );
  }

  console.log(`Migrated ${rows.length} plaintext card token(s) to hashed cards.`);
}

module.exports = db;
