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

  -- The rules that actually prevent a double booking live in the per-doctor
  -- migration further down (idx_appointments_slot_unassigned and
  -- idx_appointments_slot_per_doctor), not here — declaring a clinic-wide one
  -- here too would only show a reader a constraint that is dropped on the very
  -- next boot.

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

function appointmentColumns() {
  return db.prepare(`PRAGMA table_info(appointments)`).all().map((c) => c.name);
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

// --- Contraindication engine: hard-stop rule table ---
//
// A small curated set of well-known, high-severity allergy/medication
// conflicts, checked deterministically before a doctor saves a new
// medication or vaccination (see contraindication.js and server.js's
// "Contraindication engine" section). Gemini judgment is layered on top of
// this table in server.js, never a replacement for it.
db.exec(`
  CREATE TABLE IF NOT EXISTS contraindication_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    rule_type TEXT NOT NULL,            -- 'allergy' | 'medication'
    trigger_terms TEXT NOT NULL,        -- comma-separated keywords matched
                                         -- against an existing allergen or
                                         -- active medication name
    treatment_terms TEXT NOT NULL,      -- comma-separated keywords matched
                                         -- against the proposed treatment name
    severity TEXT NOT NULL DEFAULT 'high',
    reason TEXT NOT NULL,
    created_by INTEGER REFERENCES doctors(id),
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
  );
`);

// --- Seed: a starter set of well-known hard-stop rules ---
{
  const { n } = db.prepare(`SELECT COUNT(*) AS n FROM contraindication_rules`).get();
  if (n === 0) {
    const insert = db.prepare(
      `INSERT INTO contraindication_rules (rule_type, trigger_terms, treatment_terms, severity, reason)
       VALUES (?, ?, ?, ?, ?)`
    );
    const seed = [
      ['allergy', 'penicillin,amoxicillin,ampicillin,augmentin',
        'penicillin,amoxicillin,ampicillin,augmentin,piperacillin', 'high',
        'Penicillin-class allergy cross-reacts with all penicillin-class antibiotics and can cause a severe or anaphylactic reaction.'],
      ['allergy', 'sulfa,sulfonamide,bactrim,sulfamethoxazole',
        'sulfamethoxazole,bactrim,co-trimoxazole,sulfasalazine', 'high',
        'Sulfa allergy cross-reacts with sulfonamide antibiotics and can trigger a severe skin or systemic reaction.'],
      ['allergy', 'aspirin,nsaid,ibuprofen,naproxen',
        'ibuprofen,naproxen,aspirin,diclofenac,ketorolac', 'high',
        'NSAID/aspirin allergy cross-reacts across the NSAID class and can trigger bronchospasm or anaphylaxis.'],
      ['allergy', 'egg,eggs',
        'influenza vaccine,flu vaccine,yellow fever vaccine', 'moderate',
        'Some influenza and yellow fever vaccines are egg-based and can trigger a reaction in an egg-allergic patient.'],
      ['allergy', 'gelatin',
        'mmr,measles mumps rubella,varicella,chickenpox vaccine', 'moderate',
        'MMR and varicella vaccines contain gelatin as a stabilizer, which can trigger a reaction in a gelatin-allergic patient.'],
      ['medication', 'warfarin,coumadin',
        'ibuprofen,naproxen,aspirin,diclofenac', 'high',
        'Combining warfarin with NSAIDs significantly increases bleeding risk.'],
      ['medication', 'warfarin,coumadin',
        'ciprofloxacin,metronidazole,fluconazole', 'high',
        'These antibiotics/antifungals inhibit warfarin metabolism, increasing INR and bleeding risk.'],
      ['medication', 'warfarin,coumadin',
        'amiodarone', 'high',
        'Amiodarone inhibits warfarin metabolism, sharply increasing INR and bleeding risk.'],
      ['medication', 'phenelzine,tranylcypromine,isocarboxazid',
        'sertraline,fluoxetine,paroxetine,pseudoephedrine,phenylephrine', 'high',
        'Combining an MAOI with an SSRI or decongestant risks serotonin syndrome or a hypertensive crisis.'],
      ['medication', 'simvastatin,atorvastatin,lovastatin',
        'clarithromycin,erythromycin,itraconazole', 'high',
        'These interactions raise statin blood levels and significantly increase the risk of rhabdomyolysis.'],
      ['medication', 'methotrexate',
        'ibuprofen,naproxen,aspirin', 'moderate',
        'NSAIDs reduce methotrexate clearance, increasing the risk of methotrexate toxicity.'],
      ['medication', 'lithium',
        'ibuprofen,naproxen,diclofenac', 'moderate',
        'NSAIDs reduce renal clearance of lithium, risking lithium toxicity.'],
      ['medication', 'lisinopril,enalapril,ramipril',
        'spironolactone,potassium chloride,potassium supplement', 'moderate',
        'Combining an ACE inhibitor with a potassium-sparing agent risks dangerous hyperkalemia.'],
      ['medication', 'clopidogrel,plavix',
        'omeprazole,esomeprazole', 'moderate',
        'Omeprazole/esomeprazole can inhibit clopidogrel activation, reducing its antiplatelet effect.'],
      ['medication', 'digoxin',
        'clarithromycin,erythromycin,amiodarone', 'high',
        'These drugs raise digoxin levels, risking digoxin toxicity.'],
    ];
    for (const row of seed) insert.run(...row);
    console.log(`Seeded ${seed.length} contraindication rules.`);
  }
}

module.exports = db;
