const express = require('express');
const db = require('./db');
const { hashPassword, verifyPassword, signDoctorToken, verifyDoctorToken } = require('./auth');
const { generateCardToken, hashCardToken, previewOf } = require('./tokens');
const { rateLimit } = require('./ratelimit');

const app = express();
app.use(express.json());

// Dev request log: makes it obvious what the app is calling and when.
app.use((req, _res, next) => {
  console.log(`${new Date().toISOString()}  ${req.method} ${req.path}`);
  next();
});

// Defence in depth. Card tokens are 256-bit random so enumeration is already
// hopeless, but this also protects legacy short tokens and password guessing.
const lookupLimiter = rateLimit({
  windowMs: 60_000,
  max: Number(process.env.MEDIC_LOOKUP_LIMIT ?? 30),
  message: 'Too many card lookups. Try again shortly.',
});
const loginLimiter = rateLimit({
  windowMs: 15 * 60_000,
  max: Number(process.env.MEDIC_LOGIN_LIMIT ?? 20),
  message: 'Too many sign-in attempts. Try again later.',
});

const PATIENT_FIELDS = [
  'full_name', 'date_of_birth', 'blood_type', 'allergies',
  'medications', 'conditions', 'emergency_contact_name', 'emergency_contact_phone',
  'next_appointment', 'surgery_date', 'primary_doctor',
];

function logAudit(patientId, doctorId, action, details) {
  db.prepare(
    `INSERT INTO audit_log (patient_id, doctor_id, action, details) VALUES (?, ?, ?, ?)`
  ).run(patientId, doctorId ?? null, action, details ?? null);
}

/// Resolve a presented card token to its patient, ignoring revoked cards.
function patientForCardToken(token) {
  if (typeof token !== 'string' || token.length === 0) return null;
  const card = db.prepare(
    `SELECT * FROM cards WHERE token_hash = ? AND status = 'active'`
  ).get(hashCardToken(token));
  if (!card) return null;
  return db.prepare(`SELECT * FROM patients WHERE id = ?`).get(card.patient_id) || null;
}

/// The raw token never leaves the server after issue, so responses carry only
/// a short preview for telling cards apart.
function withCard(patient) {
  const card = db.prepare(
    `SELECT id, preview, issued_at FROM cards WHERE patient_id = ? AND status = 'active'`
  ).get(patient.id);
  return {
    ...patient,
    card_preview: card?.preview ?? null,
    card_id: card?.id ?? null,
  };
}

/// Issue a fresh card, revoking any currently active one.
function issueCard(patientId, doctorId) {
  db.prepare(
    `UPDATE cards SET status = 'revoked', revoked_at = datetime('now'), revoked_by = ?
     WHERE patient_id = ? AND status = 'active'`
  ).run(doctorId ?? null, patientId);

  const token = generateCardToken();
  const result = db.prepare(
    `INSERT INTO cards (patient_id, token_hash, preview, issued_by) VALUES (?, ?, ?, ?)`
  ).run(patientId, hashCardToken(token), previewOf(token), doctorId ?? null);

  return { token, cardId: Number(result.lastInsertRowid) };
}

function requireDoctor(req, res, next) {
  const header = req.header('Authorization') || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : null;
  if (!token) {
    return res.status(401).json({ error: 'Missing bearer token' });
  }
  let payload;
  try {
    payload = verifyDoctorToken(token);
  } catch {
    return res.status(401).json({ error: 'Invalid or expired token' });
  }
  const doctor = db.prepare(`SELECT * FROM doctors WHERE id = ?`).get(payload.sub);
  if (!doctor) {
    return res.status(401).json({ error: 'Unknown doctor' });
  }
  req.doctor = doctor;
  next();
}

// --- Doctor auth ---

app.post('/api/auth/register-doctor', (req, res) => {
  const { name, licenseNumber, email, password } = req.body;
  if (!name || !licenseNumber || !email || !password) {
    return res.status(400).json({ error: 'name, licenseNumber, email and password are required' });
  }
  const passwordHash = hashPassword(password);
  const result = db.prepare(
    `INSERT INTO doctors (name, license_number, email, password_hash) VALUES (?, ?, ?, ?)`
  ).run(name, licenseNumber, email, passwordHash);

  const doctor = { id: Number(result.lastInsertRowid), name, email };
  res.status(201).json({ doctor, token: signDoctorToken(doctor) });
});

app.post('/api/auth/login', loginLimiter, (req, res) => {
  const { email, password } = req.body;
  const doctor = db.prepare(`SELECT * FROM doctors WHERE email = ?`).get(email);
  if (!doctor || !verifyPassword(password || '', doctor.password_hash)) {
    return res.status(401).json({ error: 'Invalid email or password' });
  }
  res.json({
    doctor: { id: doctor.id, name: doctor.name, email: doctor.email },
    token: signDoctorToken(doctor),
  });
});

// --- Patients ---

// The card token is generated here, never supplied by the client, and is
// returned exactly once so it can be written to a blank tag.
app.post('/api/patients', requireDoctor, (req, res) => {
  const fields = req.body;
  if (!fields.full_name) {
    return res.status(400).json({ error: 'full_name is required' });
  }

  const columns = ['full_name'];
  const values = [fields.full_name];
  for (const key of PATIENT_FIELDS) {
    if (key === 'full_name') continue;
    if (fields[key] !== undefined) {
      columns.push(key);
      values.push(fields[key]);
    }
  }

  const placeholders = columns.map(() => '?').join(', ');
  const result = db.prepare(
    `INSERT INTO patients (${columns.join(', ')}) VALUES (${placeholders})`
  ).run(...values);

  const patientId = Number(result.lastInsertRowid);
  const { token } = issueCard(patientId, req.doctor.id);

  logAudit(patientId, req.doctor.id, 'create', 'Patient record created and card issued');
  const patient = db.prepare(`SELECT * FROM patients WHERE id = ?`).get(patientId);
  res.status(201).json({ patient: withCard(patient), cardToken: token });
});

// This is the endpoint the NFC reader will call: tap card -> look up by token
app.get('/api/patients/token/:token', lookupLimiter, (req, res) => {
  const patient = patientForCardToken(req.params.token);
  if (!patient) {
    return res.status(404).json({ error: 'No patient found for this card' });
  }

  // Doctor identity is optional here: a patient tapping their own card to
  // view their record has no doctor token, and that's a valid access too.
  const doctor = doctorFromRequest(req);
  logAudit(patient.id, doctor ? doctor.id : null, 'read', null);
  res.json(withCard(patient));
});

// --- Card lifecycle ---

app.post('/api/patients/:id/cards/reissue', requireDoctor, (req, res) => {
  const patient = db.prepare(`SELECT * FROM patients WHERE id = ?`).get(req.params.id);
  if (!patient) return res.status(404).json({ error: 'Patient not found' });

  const { token } = issueCard(patient.id, req.doctor.id);
  logAudit(patient.id, req.doctor.id, 'card_reissue', 'Old card revoked, new card issued');
  res.status(201).json({ patient: withCard(patient), cardToken: token });
});

app.post('/api/patients/:id/cards/revoke', requireDoctor, (req, res) => {
  const patient = db.prepare(`SELECT * FROM patients WHERE id = ?`).get(req.params.id);
  if (!patient) return res.status(404).json({ error: 'Patient not found' });

  const result = db.prepare(
    `UPDATE cards SET status = 'revoked', revoked_at = datetime('now'), revoked_by = ?
     WHERE patient_id = ? AND status = 'active'`
  ).run(req.doctor.id, patient.id);

  if (result.changes === 0) {
    return res.status(404).json({ error: 'No active card to revoke' });
  }
  logAudit(patient.id, req.doctor.id, 'card_revoke', 'Card revoked');
  res.json({ revoked: result.changes });
});

app.get('/api/patients/:id/cards', requireDoctor, (req, res) => {
  const cards = db.prepare(
    `SELECT id, preview, status, issued_at, revoked_at FROM cards
     WHERE patient_id = ? ORDER BY issued_at DESC`
  ).all(req.params.id);
  res.json(cards);
});

app.put('/api/patients/token/:token', requireDoctor, (req, res) => {
  const patient = patientForCardToken(req.params.token);
  if (!patient) {
    return res.status(404).json({ error: 'No patient found for this card' });
  }

  const updates = [];
  const values = [];
  const changed = [];
  for (const key of PATIENT_FIELDS) {
    if (req.body[key] !== undefined && req.body[key] !== patient[key]) {
      updates.push(`${key} = ?`);
      values.push(req.body[key]);
      changed.push(key);
    }
  }

  if (updates.length === 0) {
    return res.json(withCard(patient));
  }

  updates.push(`updated_at = datetime('now')`);
  values.push(patient.id);
  db.prepare(`UPDATE patients SET ${updates.join(', ')} WHERE id = ?`).run(...values);

  logAudit(patient.id, req.doctor.id, 'update', `Changed: ${changed.join(', ')}`);
  const updated = db.prepare(`SELECT * FROM patients WHERE id = ?`).get(patient.id);
  res.json(withCard(updated));
});

app.get('/api/patients/:id/audit', (req, res) => {
  const entries = db.prepare(
    `SELECT audit_log.*, doctors.name AS doctor_name
     FROM audit_log LEFT JOIN doctors ON doctors.id = audit_log.doctor_id
     WHERE patient_id = ? ORDER BY timestamp DESC`
  ).all(req.params.id);
  res.json(entries);
});

// --- Clinical notes (append-only timeline of updates) ---

const NOTE_TYPES = [
  'checkup', 'medication_change', 'surgery', 'appointment', 'lab_result', 'general',
];

app.post('/api/patients/:id/notes', requireDoctor, (req, res) => {
  const patient = db.prepare(`SELECT * FROM patients WHERE id = ?`).get(req.params.id);
  if (!patient) {
    return res.status(404).json({ error: 'Patient not found' });
  }
  const { noteType, body } = req.body;
  if (!body || !body.trim()) {
    return res.status(400).json({ error: 'Note body is required' });
  }
  const type = NOTE_TYPES.includes(noteType) ? noteType : 'general';

  const result = db.prepare(
    `INSERT INTO clinical_notes (patient_id, doctor_id, note_type, body) VALUES (?, ?, ?, ?)`
  ).run(patient.id, req.doctor.id, type, body.trim());

  logAudit(patient.id, req.doctor.id, 'note', `Added ${type} note`);
  const note = db.prepare(
    `SELECT clinical_notes.*, doctors.name AS doctor_name
     FROM clinical_notes LEFT JOIN doctors ON doctors.id = clinical_notes.doctor_id
     WHERE clinical_notes.id = ?`
  ).get(Number(result.lastInsertRowid));
  res.status(201).json(note);
});

app.get('/api/patients/:id/notes', (req, res) => {
  const notes = db.prepare(
    `SELECT clinical_notes.*, doctors.name AS doctor_name
     FROM clinical_notes LEFT JOIN doctors ON doctors.id = clinical_notes.doctor_id
     WHERE patient_id = ? ORDER BY created_at DESC`
  ).all(req.params.id);
  res.json(notes);
});

// --- Self-measured readings ---
//
// Writable by whoever holds the card (the patient), unlike the clinical
// record. Each row records its `source` so a self-reported value is never
// confused with a clinician-verified one. Units follow Malaysian clinical
// convention: mmol/L for glucose and cholesterol, umol/L for uric acid.

const READING_TYPES = {
  blood_sugar: { unit: 'mmol/L', max: 60 },
  cholesterol: { unit: 'mmol/L', max: 30 },
  uric_acid: { unit: 'umol/L', max: 1500 },
};

/// Returns the doctor for a valid bearer token, or null.
function doctorFromRequest(req) {
  const header = req.header('Authorization') || '';
  if (!header.startsWith('Bearer ')) return null;
  try {
    const payload = verifyDoctorToken(header.slice(7));
    return db.prepare(`SELECT * FROM doctors WHERE id = ?`).get(payload.sub) || null;
  } catch {
    return null;
  }
}

app.post('/api/patients/token/:token/readings', lookupLimiter, (req, res) => {
  const patient = patientForCardToken(req.params.token);
  if (!patient) {
    return res.status(404).json({ error: 'No patient found for this card' });
  }

  const { readingType, value, note, takenAt } = req.body;
  const spec = READING_TYPES[readingType];
  if (!spec) {
    return res.status(400).json({
      error: `readingType must be one of: ${Object.keys(READING_TYPES).join(', ')}`,
    });
  }

  const numeric = Number(value);
  if (!Number.isFinite(numeric) || numeric <= 0 || numeric > spec.max) {
    return res.status(400).json({
      error: `value must be a number between 0 and ${spec.max} ${spec.unit}`,
    });
  }

  // A signed-in doctor entering a reading is attributed to them; anyone else
  // holding the card is recorded as self-reported.
  const doctor = doctorFromRequest(req);
  const source = doctor ? 'doctor' : 'patient';

  const result = db.prepare(
    `INSERT INTO readings (patient_id, doctor_id, reading_type, value, unit, note, source, taken_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, COALESCE(?, datetime('now')))`
  ).run(
    patient.id,
    doctor ? doctor.id : null,
    readingType,
    numeric,
    spec.unit,
    note?.trim() || null,
    source,
    takenAt || null,
  );

  logAudit(patient.id, doctor ? doctor.id : null, 'reading',
    `${source} recorded ${readingType}: ${numeric} ${spec.unit}`);

  const reading = db.prepare(
    `SELECT readings.*, doctors.name AS doctor_name
     FROM readings LEFT JOIN doctors ON doctors.id = readings.doctor_id
     WHERE readings.id = ?`
  ).get(Number(result.lastInsertRowid));
  res.status(201).json(reading);
});

app.get('/api/patients/:id/readings', (req, res) => {
  const { type } = req.query;
  const rows = type
    ? db.prepare(
        `SELECT readings.*, doctors.name AS doctor_name
         FROM readings LEFT JOIN doctors ON doctors.id = readings.doctor_id
         WHERE patient_id = ? AND reading_type = ? ORDER BY taken_at DESC`
      ).all(req.params.id, type)
    : db.prepare(
        `SELECT readings.*, doctors.name AS doctor_name
         FROM readings LEFT JOIN doctors ON doctors.id = readings.doctor_id
         WHERE patient_id = ? ORDER BY taken_at DESC`
      ).all(req.params.id);
  res.json(rows);
});

const PORT = 3000;
app.listen(PORT, () => {
  console.log(`MedThru API listening on http://localhost:${PORT}`);
});
