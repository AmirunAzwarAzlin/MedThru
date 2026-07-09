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
`);

function patientColumns() {
  return db.prepare(`PRAGMA table_info(patients)`).all().map((c) => c.name);
}

// --- Migration 1: structured care-plan columns ---
{
  const cols = patientColumns();
  const added = {
    next_appointment: 'TEXT',
    surgery_date: 'TEXT',
    primary_doctor: 'TEXT',
  };
  for (const [name, type] of Object.entries(added)) {
    if (!cols.includes(name)) {
      db.exec(`ALTER TABLE patients ADD COLUMN ${name} ${type}`);
    }
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
