require('dotenv').config();
const express = require('express');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const db = require('./db');
const {
  hashPassword,
  verifyPassword,
  signDoctorToken,
  verifyDoctorToken,
  signPatientToken,
  verifyPatientToken,
} = require('./auth');
const { generateCardToken, hashCardToken, previewOf } = require('./tokens');
const { rateLimit } = require('./ratelimit');
const {
  HELD_STATUSES,
  STATUSES,
  DOCTOR_DECISIONS,
  ALLOWED_TRANSITIONS,
  availableSlots,
  bookingError,
  clinicError,
  isValidDate,
  normalizeStartsAt,
  toDateString,
  MAX_ADVANCE_DAYS,
} = require('./appointments');
const { urgencyTag, rankCandidates } = require('./reschedule');
const { rationalizeCandidates, orderedStartsAts } = require('./gemini');
const { checkHardStops } = require('./contraindication');
const { judgeContraindication } = require('./contraindication-gemini');

const app = express();
// Documents arrive as base64 inside JSON, so the body limit has to clear a
// typical scan or photo. 20 MB covers that while still capping abuse.
app.use(express.json({ limit: '20mb' }));

// Uploaded document bytes live on disk, not in the database.
const UPLOAD_DIR = path.join(__dirname, 'uploads');
fs.mkdirSync(UPLOAD_DIR, { recursive: true });
const MAX_DOC_BYTES = 15 * 1024 * 1024;
const EXT_BY_MIME = {
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'image/webp': 'webp',
  'image/heic': 'heic',
  'image/gif': 'gif',
  'application/pdf': 'pdf',
};

/// The client-safe view of a document row — never exposes the on-disk name.
function documentMeta(row) {
  return {
    id: row.id,
    filename: row.filename,
    mime_type: row.mime_type,
    size_bytes: row.size_bytes,
    source: row.source,
    doctor_name: row.doctor_name ?? null,
    created_at: row.created_at,
  };
}

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
  'next_appointment', 'surgery_date', 'primary_doctor', 'gender',
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
  const { password_hash, ...safe } = patient;
  const card = db.prepare(
    `SELECT id, preview, issued_at FROM cards WHERE patient_id = ? AND status = 'active'`
  ).get(patient.id);
  return {
    ...safe,
    card_preview: card?.preview ?? null,
    card_id: card?.id ?? null,
    // Never the hash itself -- just whether a tap needs to be followed by a
    // password prompt. Absent until the patient sets up phone login, so a
    // tap keeps working unguarded until they've opted in.
    has_password: password_hash != null,
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

/// Chains after requireDoctor. A handful of actions — reissuing/revoking a
/// card, deleting a patient record outright — are administrator-only, not
/// something every doctor account can do.
function requireAdmin(req, res, next) {
  if (!req.doctor.is_admin) {
    return res.status(403).json({ error: 'Administrator access required' });
  }
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

  const doctor = db.prepare(`SELECT * FROM doctors WHERE id = ?`).get(Number(result.lastInsertRowid));
  res.status(201).json({ doctor: doctorProfile(doctor), token: signDoctorToken(doctor) });
});

app.post('/api/auth/login', loginLimiter, (req, res) => {
  const { email, password } = req.body;
  const doctor = db.prepare(`SELECT * FROM doctors WHERE email = ?`).get(email);
  if (!doctor || !verifyPassword(password || '', doctor.password_hash)) {
    return res.status(401).json({ error: 'Invalid email or password' });
  }
  res.json({
    doctor: doctorProfile(doctor),
    token: signDoctorToken(doctor),
  });
});

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
  };
}

app.get('/api/auth/me', requireDoctor, (req, res) => {
  res.json(doctorProfile(req.doctor));
});

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

app.post('/api/auth/change-password', requireDoctor, (req, res) => {
  const { currentPassword, newPassword } = req.body;
  if (!currentPassword || !newPassword) {
    return res.status(400).json({ error: 'currentPassword and newPassword are required' });
  }
  if (!verifyPassword(currentPassword, req.doctor.password_hash)) {
    return res.status(401).json({ error: 'Current password is incorrect' });
  }
  if (newPassword.length < 8) {
    return res.status(400).json({ error: 'New password must be at least 8 characters' });
  }
  db.prepare(`UPDATE doctors SET password_hash = ? WHERE id = ?`)
    .run(hashPassword(newPassword), req.doctor.id);
  res.json({ ok: true });
});

// Alternative to a card tap, for a patient who set up phone + password
// login while they held their card. Rate-limited like doctor login since
// it's a password guess surface.
app.post('/api/auth/patient-login', loginLimiter, (req, res) => {
  const { phone, password } = req.body;
  const patient = phone
    ? db.prepare(`SELECT * FROM patients WHERE phone = ?`).get(String(phone).trim())
    : null;
  if (!patient || !patient.password_hash || !verifyPassword(password || '', patient.password_hash)) {
    return res.status(401).json({ error: 'Invalid phone number or password' });
  }
  logAudit(patient.id, null, 'read', 'Signed in with phone login');
  res.json({ patient: withCard(patient), token: signPatientToken(patient) });
});

// --- Patients ---

/// Doctor-only directory: every registered patient, optionally filtered by
/// name. Exists so a doctor can find someone without their card in hand —
/// unlike the token-based routes below, this never needs a card to work.
app.get('/api/patients', requireDoctor, (req, res) => {
  const q = typeof req.query.q === 'string' ? req.query.q.trim() : '';
  const select = `
    SELECT patients.id, patients.full_name, patients.date_of_birth, patients.blood_type,
           cards.preview AS card_preview, cards.status AS card_status
    FROM patients
    LEFT JOIN cards ON cards.patient_id = patients.id AND cards.status = 'active'
  `;
  const rows = q
    ? db.prepare(`${select} WHERE patients.full_name LIKE ? ORDER BY patients.full_name`)
        .all(`%${q}%`)
    : db.prepare(`${select} ORDER BY patients.full_name`).all();
  res.json(rows);
});

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

/// Doctor-only single-patient fetch by id — the counterpart to the token
/// lookup, for browsing without a card (e.g. from the directory).
app.get('/api/patients/:id', requireDoctor, (req, res) => {
  const patient = db.prepare(`SELECT * FROM patients WHERE id = ?`).get(req.params.id);
  if (!patient) {
    return res.status(404).json({ error: 'Patient not found' });
  }
  res.json(withCard(patient));
});

/// Doctor-only: permanently remove a patient and everything tied to their
/// record (cards, notes, readings, health records, appointments, audit
/// history). This connection doesn't enforce foreign keys (see the
/// migration above), so each child table is cleared explicitly rather than
/// relying on a cascade — and the deletion itself is deliberately not
/// audit-logged, since the audit trail for this patient is being wiped too.
app.delete('/api/patients/:id', requireDoctor, requireAdmin, (req, res) => {
  const patient = db.prepare(`SELECT * FROM patients WHERE id = ?`).get(req.params.id);
  if (!patient) {
    return res.status(404).json({ error: 'Patient not found' });
  }

  const childTables = [
    'cards', 'audit_log', 'clinical_notes', 'readings', 'allergies',
    'medications', 'vaccinations', 'medical_history', 'emergency_contacts',
    'appointments',
  ];

  db.exec('BEGIN');
  try {
    for (const table of childTables) {
      db.prepare(`DELETE FROM ${table} WHERE patient_id = ?`).run(patient.id);
    }
    db.prepare(`DELETE FROM patients WHERE id = ?`).run(patient.id);
    db.exec('COMMIT');
  } catch (err) {
    db.exec('ROLLBACK');
    throw err;
  }

  res.json({ deleted: true });
});

// This is the endpoint the NFC reader will call: tap card -> look up by token
app.get('/api/patients/token/:token', lookupLimiter, (req, res) => {
  const patient = resolvePatientFromReq(req);
  if (!patient) {
    return res.status(404).json({ error: 'No patient found for this card' });
  }

  // Doctor identity is optional here: a patient tapping their own card to
  // view their record has no doctor token, and that's a valid access too.
  const doctor = doctorFromRequest(req);

  // A raw physical-card tap -- not a doctor, and not a "me" phone session
  // (which already proved the password once, at sign-in) -- additionally
  // has to prove the card's password, once the patient has opted into one.
  // Protects a lost or stolen card from handing over the full record to
  // whoever just finds it. Doctors and the public /emergency/:token page
  // (a separate route entirely, for a first responder) are unaffected.
  const isRawCardTap = !doctor && req.params.token !== 'me';
  if (isRawCardTap && patient.password_hash) {
    const password = typeof req.query.password === 'string' ? req.query.password : '';
    if (!verifyPassword(password, patient.password_hash)) {
      return res.status(401).json({ error: 'This card requires its password', passwordRequired: true });
    }
  }

  logAudit(patient.id, doctor ? doctor.id : null, 'read', null);
  res.json(withCard(patient));
});

// A patient editing their own identity — name and date of birth. Deliberately
// narrower than the doctor-only PUT below, which also covers clinical
// fields (blood type, medications, care plan, ...) that stay doctor-verified.
app.put('/api/patients/token/:token/profile', lookupLimiter, (req, res) => {
  const patient = resolvePatientFromReq(req);
  if (!patient) {
    return res.status(404).json({ error: 'No patient found for this card' });
  }

  const { fullName, dateOfBirth, gender } = req.body;
  if (fullName !== undefined && !String(fullName).trim()) {
    return res.status(400).json({ error: 'fullName cannot be blank' });
  }

  const updates = [];
  const values = [];
  const changed = [];
  if (fullName !== undefined) {
    updates.push('full_name = ?');
    values.push(String(fullName).trim());
    changed.push('full_name');
  }
  if (dateOfBirth !== undefined) {
    updates.push('date_of_birth = ?');
    values.push(dateOfBirth || null);
    changed.push('date_of_birth');
  }
  if (gender !== undefined) {
    updates.push('gender = ?');
    values.push(optionalText(gender));
    changed.push('gender');
  }

  if (updates.length === 0) {
    return res.json(withCard(patient));
  }

  updates.push(`updated_at = datetime('now')`);
  values.push(patient.id);
  db.prepare(`UPDATE patients SET ${updates.join(', ')} WHERE id = ?`).run(...values);

  const doctor = doctorFromRequest(req);
  logAudit(patient.id, doctor ? doctor.id : null, 'update', `Changed: ${changed.join(', ')}`);
  const updated = db.prepare(`SELECT * FROM patients WHERE id = ?`).get(patient.id);
  res.json(withCard(updated));
});

// Bind a phone + password to this patient so they can sign in without the
// physical card. Requires a valid card token to prove possession at setup
// time — 'me' is not accepted here, it would be circular.
app.post('/api/patients/token/:token/login-setup', lookupLimiter, (req, res) => {
  if (req.params.token === 'me') {
    return res.status(400).json({ error: 'Card required to set up phone login' });
  }
  const patient = patientForCardToken(req.params.token);
  if (!patient) {
    return res.status(404).json({ error: 'No patient found for this card' });
  }

  const { phone, password } = req.body;
  if (!phone || !String(phone).trim()) {
    return res.status(400).json({ error: 'phone is required' });
  }
  if (!password || password.length < 8) {
    return res.status(400).json({ error: 'password must be at least 8 characters' });
  }

  try {
    db.prepare(`UPDATE patients SET phone = ?, password_hash = ?, updated_at = datetime('now') WHERE id = ?`)
      .run(String(phone).trim(), hashPassword(password), patient.id);
  } catch (err) {
    if (String(err.message).includes('UNIQUE')) {
      return res.status(409).json({ error: 'That phone number is already registered.' });
    }
    throw err;
  }

  logAudit(patient.id, null, 'login_setup', 'Phone login enabled');
  res.json({ ok: true });
});

// --- Card lifecycle ---

app.post('/api/patients/:id/cards/reissue', requireDoctor, requireAdmin, (req, res) => {
  const patient = db.prepare(`SELECT * FROM patients WHERE id = ?`).get(req.params.id);
  if (!patient) return res.status(404).json({ error: 'Patient not found' });

  const { token } = issueCard(patient.id, req.doctor.id);
  logAudit(patient.id, req.doctor.id, 'card_reissue', 'Old card revoked, new card issued');
  res.status(201).json({ patient: withCard(patient), cardToken: token });
});

app.post('/api/patients/:id/cards/revoke', requireDoctor, requireAdmin, (req, res) => {
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

app.get('/api/patients/:id/audit', requireDoctor, (req, res) => {
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
  // Vital signs
  blood_pressure_systolic: { unit: 'mmHg', max: 300 },
  blood_pressure_diastolic: { unit: 'mmHg', max: 200 },
  heart_rate: { unit: 'bpm', max: 300 },
  temperature: { unit: '°C', max: 45 },
  // Anthropometry
  weight: { unit: 'kg', max: 500 },
  height: { unit: 'cm', max: 250 },
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

/// A patient who signed in with phone + password instead of tapping their
/// card, identified by their own bearer token (never a doctor's).
function patientFromPatientSession(req) {
  const header = req.header('Authorization') || '';
  if (!header.startsWith('Bearer ')) return null;
  try {
    const payload = verifyPatientToken(header.slice(7));
    return db.prepare(`SELECT * FROM patients WHERE id = ?`).get(payload.sub) || null;
  } catch {
    return null;
  }
}

/// Resolves the patient behind a `/token/:token` route. The literal segment
/// "me" stands in for "whoever the bearer token says I am" so a patient who
/// set up phone + password login can reach the same endpoints a card tap
/// uses, without the server ever having to re-issue their raw card token.
function resolvePatientFromReq(req) {
  if (req.params.token === 'me') return patientFromPatientSession(req);
  return patientForCardToken(req.params.token);
}

app.post('/api/patients/token/:token/readings', lookupLimiter, (req, res) => {
  const patient = resolvePatientFromReq(req);
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

/// Remove a mistaken reading. Scoped to the cardholder, like editing a
/// health record entry — presenting one card never deletes another
/// patient's reading, even with a valid reading id.
app.delete('/api/patients/token/:token/readings/:id', lookupLimiter, (req, res) => {
  const patient = resolvePatientFromReq(req);
  if (!patient) {
    return res.status(404).json({ error: 'No patient found for this card' });
  }
  const existing = db.prepare(`SELECT * FROM readings WHERE id = ? AND patient_id = ?`)
    .get(req.params.id, patient.id);
  if (!existing) {
    return res.status(404).json({ error: 'Reading not found' });
  }

  db.prepare(`DELETE FROM readings WHERE id = ?`).run(existing.id);

  const doctor = doctorFromRequest(req);
  logAudit(patient.id, doctor ? doctor.id : null, 'reading_delete',
    `Deleted a ${existing.reading_type} reading`);
  res.json({ deleted: true });
});

// --- Health records ---
//
// Allergies, medications, vaccinations and medical history: structured,
// dated entries with their own fields (unlike readings, which are just a
// number). One table per category, but the same shape of endpoints, so a
// single registration function covers all four instead of repeating the
// create/list/list-by-patient trio four times over.

/// A field copied from the request body into an insert column. `default` is
/// used when the value is missing or blank, so e.g. medical history status
/// falls back to 'active' instead of overwriting the column's SQL default
/// with an explicit NULL.
function bodyValue(req, col) {
  let v = req.body[col.body];
  if (typeof v === 'string') v = v.trim() || null;
  if (v === undefined) v = null;
  if (v === null && col.default !== undefined) v = col.default;
  return v;
}

function registerHealthRecords({ path, table, requiredKeys, columns, orderBy }) {
  const rowSelect = `SELECT ${table}.*, doctors.name AS doctor_name
    FROM ${table} LEFT JOIN doctors ON doctors.id = ${table}.doctor_id`;

  app.post(`/api/patients/token/:token/${path}`, lookupLimiter, (req, res) => {
    const patient = resolvePatientFromReq(req);
    if (!patient) {
      return res.status(404).json({ error: 'No patient found for this card' });
    }

    for (const key of requiredKeys) {
      const v = req.body[key];
      if (v === undefined || v === null || (typeof v === 'string' && !v.trim())) {
        return res.status(400).json({ error: `${key} is required` });
      }
    }

    const doctor = doctorFromRequest(req);
    const dbColumns = ['patient_id', ...columns.map((c) => c.db), 'doctor_id', 'source'];
    const values = [
      patient.id,
      ...columns.map((c) => bodyValue(req, c)),
      doctor ? doctor.id : null,
      doctor ? 'doctor' : 'patient',
    ];
    const placeholders = dbColumns.map(() => '?').join(', ');
    const result = db.prepare(
      `INSERT INTO ${table} (${dbColumns.join(', ')}) VALUES (${placeholders})`
    ).run(...values);

    logAudit(patient.id, doctor ? doctor.id : null, `${table}_add`, `Added a ${path} entry`);
    const row = db.prepare(`${rowSelect} WHERE ${table}.id = ?`)
      .get(Number(result.lastInsertRowid));
    res.status(201).json(row);
  });

  /// A patient's own entries, reached with their card (or phone session).
  app.get(`/api/patients/token/:token/${path}`, lookupLimiter, (req, res) => {
    const patient = resolvePatientFromReq(req);
    if (!patient) {
      return res.status(404).json({ error: 'No patient found for this card' });
    }
    res.json(db.prepare(`${rowSelect} WHERE ${table}.patient_id = ? ORDER BY ${orderBy}`).all(patient.id));
  });

  /// Doctor-side view by patient id, alongside notes and readings.
  app.get(`/api/patients/:id/${path}`, (req, res) => {
    res.json(db.prepare(`${rowSelect} WHERE ${table}.patient_id = ? ORDER BY ${orderBy}`).all(req.params.id));
  });

  /// Correct an entry. Scoped to the cardholder: presenting one card never
  /// edits another patient's entry, even with a valid entry id.
  app.put(`/api/patients/token/:token/${path}/:id`, lookupLimiter, (req, res) => {
    const patient = resolvePatientFromReq(req);
    if (!patient) {
      return res.status(404).json({ error: 'No patient found for this card' });
    }
    const existing = db.prepare(`SELECT * FROM ${table} WHERE id = ? AND patient_id = ?`)
      .get(req.params.id, patient.id);
    if (!existing) {
      return res.status(404).json({ error: 'Entry not found' });
    }

    for (const key of requiredKeys) {
      const v = req.body[key];
      if (v === undefined || v === null || (typeof v === 'string' && !v.trim())) {
        return res.status(400).json({ error: `${key} is required` });
      }
    }

    const setClause = columns.map((c) => `${c.db} = ?`).join(', ');
    const values = columns.map((c) => bodyValue(req, c));
    db.prepare(`UPDATE ${table} SET ${setClause} WHERE id = ?`).run(...values, existing.id);

    const doctor = doctorFromRequest(req);
    logAudit(patient.id, doctor ? doctor.id : null, `${table}_edit`, `Edited a ${path} entry`);
    res.json(db.prepare(`${rowSelect} WHERE ${table}.id = ?`).get(existing.id));
  });

  /// Remove an entry, e.g. one added by mistake. Same cardholder scoping as edit.
  app.delete(`/api/patients/token/:token/${path}/:id`, lookupLimiter, (req, res) => {
    const patient = resolvePatientFromReq(req);
    if (!patient) {
      return res.status(404).json({ error: 'No patient found for this card' });
    }
    const existing = db.prepare(`SELECT * FROM ${table} WHERE id = ? AND patient_id = ?`)
      .get(req.params.id, patient.id);
    if (!existing) {
      return res.status(404).json({ error: 'Entry not found' });
    }

    db.prepare(`DELETE FROM ${table} WHERE id = ?`).run(existing.id);

    const doctor = doctorFromRequest(req);
    logAudit(patient.id, doctor ? doctor.id : null, `${table}_delete`, `Deleted a ${path} entry`);
    res.json({ deleted: true });
  });
}

registerHealthRecords({
  path: 'allergies',
  table: 'allergies',
  requiredKeys: ['allergen'],
  columns: [
    { body: 'allergen', db: 'allergen' },
    { body: 'reaction', db: 'reaction' },
    { body: 'severity', db: 'severity' },
    { body: 'note', db: 'note' },
  ],
  orderBy: 'created_at DESC',
});

registerHealthRecords({
  path: 'medications',
  table: 'medications',
  requiredKeys: ['name'],
  columns: [
    { body: 'name', db: 'name' },
    { body: 'dosage', db: 'dosage' },
    { body: 'frequency', db: 'frequency' },
    { body: 'startDate', db: 'start_date' },
    { body: 'endDate', db: 'end_date' },
    { body: 'note', db: 'note' },
  ],
  orderBy: 'created_at DESC',
});

registerHealthRecords({
  path: 'vaccinations',
  table: 'vaccinations',
  requiredKeys: ['vaccine', 'administeredAt'],
  columns: [
    { body: 'vaccine', db: 'vaccine' },
    { body: 'doseNumber', db: 'dose_number' },
    { body: 'administeredAt', db: 'administered_at' },
    { body: 'nextDue', db: 'next_due' },
    { body: 'note', db: 'note' },
  ],
  orderBy: 'administered_at DESC',
});

registerHealthRecords({
  path: 'medical-history',
  table: 'medical_history',
  requiredKeys: ['conditionName'],
  columns: [
    { body: 'conditionName', db: 'condition_name' },
    { body: 'diagnosedAt', db: 'diagnosed_at' },
    { body: 'status', db: 'status', default: 'active' },
    { body: 'note', db: 'note' },
  ],
  orderBy: 'created_at DESC',
});

registerHealthRecords({
  path: 'emergency-contacts',
  table: 'emergency_contacts',
  requiredKeys: ['name', 'phone'],
  columns: [
    { body: 'name', db: 'name' },
    { body: 'phone', db: 'phone' },
    { body: 'relationship', db: 'relationship' },
    { body: 'note', db: 'note' },
  ],
  orderBy: 'created_at DESC',
});

registerHealthRecords({
  path: 'lab-results',
  table: 'lab_results',
  requiredKeys: ['testName'],
  columns: [
    { body: 'testName', db: 'test_name' },
    { body: 'value', db: 'value' },
    { body: 'unit', db: 'unit' },
    { body: 'referenceRange', db: 'reference_range' },
    { body: 'status', db: 'status', default: 'normal' },
    { body: 'takenAt', db: 'taken_at' },
    { body: 'note', db: 'note' },
  ],
  orderBy: 'taken_at DESC, created_at DESC',
});

// --- Contraindication engine ---
//
// Cross-references a proposed medication or vaccination against the
// patient's logged allergies and active medications before it's saved. A
// deterministic hard-stop rule table (contraindication_rules) always runs
// first and can never be silently overridden; Gemini only judges the softer
// cases left over once the hard-stop table finds nothing (see
// contraindication.js / contraindication-gemini.js). Doctor-only: this is
// about a doctor proposing a *new* treatment, not a patient's own
// self-reported entries.

const TREATMENT_TYPES = ['medication', 'vaccination'];

function activeMedicationNames(patientId) {
  return db.prepare(
    `SELECT name FROM medications
     WHERE patient_id = ? AND (end_date IS NULL OR end_date >= date('now'))`
  ).all(patientId);
}

function activeMedicationsDetailed(patientId) {
  return db.prepare(
    `SELECT name, dosage, frequency FROM medications
     WHERE patient_id = ? AND (end_date IS NULL OR end_date >= date('now'))`
  ).all(patientId);
}

app.post('/api/patients/token/:token/contraindication-check', lookupLimiter, requireDoctor, async (req, res) => {
  const patient = resolvePatientFromReq(req);
  if (!patient) {
    return res.status(404).json({ error: 'No patient found for this card' });
  }

  const { treatmentType, treatmentName, dosage } = req.body;
  if (!TREATMENT_TYPES.includes(treatmentType)) {
    return res.status(400).json({ error: `treatmentType must be one of: ${TREATMENT_TYPES.join(', ')}` });
  }
  if (typeof treatmentName !== 'string' || !treatmentName.trim()) {
    return res.status(400).json({ error: 'treatmentName is required' });
  }

  const allergenRows = db.prepare(`SELECT allergen FROM allergies WHERE patient_id = ?`).all(patient.id);
  const rules = db.prepare(`SELECT * FROM contraindication_rules`).all();

  const hardStops = checkHardStops({
    rules,
    allergies: allergenRows,
    medications: activeMedicationNames(patient.id),
    proposedName: treatmentName,
  });

  let aiFlag = null;
  if (hardStops.length === 0) {
    aiFlag = await judgeContraindication({
      allergies: db.prepare(`SELECT allergen, reaction, severity FROM allergies WHERE patient_id = ?`).all(patient.id),
      medications: activeMedicationsDetailed(patient.id),
      proposedTreatment: { name: treatmentName, type: treatmentType, dosage: dosage || null },
    });
  }

  if (hardStops.length > 0 || aiFlag) {
    logAudit(patient.id, req.doctor.id, 'contraindication_flagged', JSON.stringify({
      treatmentType,
      treatmentName,
      hardStopRuleIds: hardStops.map((h) => h.ruleId),
      aiFlag,
    }));
  }

  res.json({ hardStops, aiFlag });
});

app.post('/api/patients/token/:token/contraindication-override', lookupLimiter, requireDoctor, (req, res) => {
  const patient = resolvePatientFromReq(req);
  if (!patient) {
    return res.status(404).json({ error: 'No patient found for this card' });
  }

  const { ruleIds, reason, treatmentName } = req.body;
  if (typeof reason !== 'string' || !reason.trim()) {
    return res.status(400).json({ error: 'reason is required' });
  }
  if (typeof treatmentName !== 'string' || !treatmentName.trim()) {
    return res.status(400).json({ error: 'treatmentName is required' });
  }

  logAudit(patient.id, req.doctor.id, 'contraindication_override', JSON.stringify({
    treatmentName,
    ruleIds: Array.isArray(ruleIds) ? ruleIds : [],
    reason: reason.trim(),
  }));

  res.status(201).json({ logged: true });
});

app.get('/api/contraindication-rules', requireDoctor, (_req, res) => {
  res.json(db.prepare(`SELECT * FROM contraindication_rules ORDER BY rule_type, id`).all());
});

function contraindicationRuleError({ ruleType, triggerTerms, treatmentTerms, reason }) {
  if (!['allergy', 'medication'].includes(ruleType)) {
    return `ruleType must be 'allergy' or 'medication'`;
  }
  if (typeof triggerTerms !== 'string' || !triggerTerms.trim()) {
    return 'triggerTerms is required';
  }
  if (typeof treatmentTerms !== 'string' || !treatmentTerms.trim()) {
    return 'treatmentTerms is required';
  }
  if (typeof reason !== 'string' || !reason.trim()) {
    return 'reason is required';
  }
  return null;
}

app.post('/api/contraindication-rules', requireDoctor, requireAdmin, (req, res) => {
  const problem = contraindicationRuleError(req.body);
  if (problem) return res.status(400).json({ error: problem });

  const { ruleType, triggerTerms, treatmentTerms, severity, reason } = req.body;
  const result = db.prepare(
    `INSERT INTO contraindication_rules (rule_type, trigger_terms, treatment_terms, severity, reason, created_by)
     VALUES (?, ?, ?, ?, ?, ?)`
  ).run(ruleType, triggerTerms.trim(), treatmentTerms.trim(), severity || 'high', reason.trim(), req.doctor.id);

  res.status(201).json(
    db.prepare(`SELECT * FROM contraindication_rules WHERE id = ?`).get(Number(result.lastInsertRowid))
  );
});

app.put('/api/contraindication-rules/:id', requireDoctor, requireAdmin, (req, res) => {
  const existing = db.prepare(`SELECT * FROM contraindication_rules WHERE id = ?`).get(req.params.id);
  if (!existing) {
    return res.status(404).json({ error: 'Rule not found' });
  }

  const problem = contraindicationRuleError(req.body);
  if (problem) return res.status(400).json({ error: problem });

  const { ruleType, triggerTerms, treatmentTerms, severity, reason } = req.body;
  db.prepare(
    `UPDATE contraindication_rules
     SET rule_type = ?, trigger_terms = ?, treatment_terms = ?, severity = ?, reason = ?, updated_at = datetime('now')
     WHERE id = ?`
  ).run(ruleType, triggerTerms.trim(), treatmentTerms.trim(), severity || 'high', reason.trim(), existing.id);

  res.json(db.prepare(`SELECT * FROM contraindication_rules WHERE id = ?`).get(existing.id));
});

app.delete('/api/contraindication-rules/:id', requireDoctor, requireAdmin, (req, res) => {
  const existing = db.prepare(`SELECT * FROM contraindication_rules WHERE id = ?`).get(req.params.id);
  if (!existing) {
    return res.status(404).json({ error: 'Rule not found' });
  }
  db.prepare(`DELETE FROM contraindication_rules WHERE id = ?`).run(existing.id);
  res.json({ deleted: true });
});

// --- Documents ---
//
// Files don't fit the registerHealthRecords shape (bytes on disk, a binary
// download), so they get their own handlers. Uploads come in as base64 inside
// JSON — consistent with the rest of the API — are written under uploads/ with
// a random name, and are streamed back by id.

const DOC_ROW_SELECT = `SELECT documents.*, doctors.name AS doctor_name
  FROM documents LEFT JOIN doctors ON doctors.id = documents.doctor_id`;

app.post('/api/patients/token/:token/documents', lookupLimiter, (req, res) => {
  const patient = resolvePatientFromReq(req);
  if (!patient) {
    return res.status(404).json({ error: 'No patient found for this card' });
  }

  const { filename, mimeType, dataBase64 } = req.body;
  if (!filename || !String(filename).trim()) {
    return res.status(400).json({ error: 'filename is required' });
  }
  if (typeof dataBase64 !== 'string' || dataBase64.length === 0) {
    return res.status(400).json({ error: 'dataBase64 is required' });
  }

  const buf = Buffer.from(dataBase64, 'base64');
  if (buf.length === 0) {
    return res.status(400).json({ error: 'File is empty or not valid base64' });
  }
  if (buf.length > MAX_DOC_BYTES) {
    return res.status(413).json({ error: 'File too large (max 15 MB)' });
  }

  // Never build the stored path from anything the client controls.
  const extFromName = path.extname(String(filename)).replace('.', '').toLowerCase();
  const ext = (EXT_BY_MIME[mimeType] || extFromName || 'bin').slice(0, 8);
  const storedName = `${crypto.randomBytes(16).toString('hex')}.${ext}`;
  fs.writeFileSync(path.join(UPLOAD_DIR, storedName), buf);

  const doctor = doctorFromRequest(req);
  const result = db.prepare(
    `INSERT INTO documents
       (patient_id, filename, mime_type, size_bytes, stored_name, doctor_id, source)
     VALUES (?, ?, ?, ?, ?, ?, ?)`
  ).run(
    patient.id,
    String(filename).trim().slice(0, 255),
    typeof mimeType === 'string' ? mimeType.slice(0, 100) : null,
    buf.length,
    storedName,
    doctor ? doctor.id : null,
    doctor ? 'doctor' : 'patient',
  );

  logAudit(patient.id, doctor ? doctor.id : null, 'documents_add', `Uploaded ${filename}`);
  const row = db.prepare(`${DOC_ROW_SELECT} WHERE documents.id = ?`).get(Number(result.lastInsertRowid));
  res.status(201).json(documentMeta(row));
});

/// A patient's document metadata by id — open, matching the other by-id reads.
app.get('/api/patients/:id/documents', (req, res) => {
  const rows = db.prepare(
    `${DOC_ROW_SELECT} WHERE documents.patient_id = ? ORDER BY documents.created_at DESC`
  ).all(req.params.id);
  res.json(rows.map(documentMeta));
});

/// Stream the actual file bytes. Random stored name + basename() keep this from
/// ever reading outside the uploads directory.
app.get('/api/patients/:id/documents/:docId/file', (req, res) => {
  const row = db.prepare(
    `SELECT * FROM documents WHERE id = ? AND patient_id = ?`
  ).get(req.params.docId, req.params.id);
  if (!row) {
    return res.status(404).json({ error: 'Document not found' });
  }
  const filePath = path.join(UPLOAD_DIR, path.basename(row.stored_name));
  if (!fs.existsSync(filePath)) {
    return res.status(404).json({ error: 'File is missing on the server' });
  }
  if (row.mime_type) res.type(row.mime_type);
  res.setHeader(
    'Content-Disposition',
    `inline; filename="${String(row.filename).replace(/["\r\n]/g, '')}"`
  );
  fs.createReadStream(filePath).pipe(res);
});

app.delete('/api/patients/token/:token/documents/:id', lookupLimiter, (req, res) => {
  const patient = resolvePatientFromReq(req);
  if (!patient) {
    return res.status(404).json({ error: 'No patient found for this card' });
  }
  const row = db.prepare(
    `SELECT * FROM documents WHERE id = ? AND patient_id = ?`
  ).get(req.params.id, patient.id);
  if (!row) {
    return res.status(404).json({ error: 'Document not found' });
  }
  try {
    fs.unlinkSync(path.join(UPLOAD_DIR, path.basename(row.stored_name)));
  } catch {
    // The row is what the app sees; a missing file shouldn't block the delete.
  }
  db.prepare(`DELETE FROM documents WHERE id = ?`).run(row.id);
  const doctor = doctorFromRequest(req);
  logAudit(patient.id, doctor ? doctor.id : null, 'documents_delete', `Deleted ${row.filename}`);
  res.json({ deleted: true });
});

// --- Messages ---

const MESSAGE_SELECT = `SELECT messages.id, messages.sender, messages.body,
  messages.created_at, doctors.name AS doctor_name
  FROM messages LEFT JOIN doctors ON doctors.id = messages.doctor_id`;

function messageThread(patientId) {
  return db.prepare(
    `${MESSAGE_SELECT} WHERE messages.patient_id = ?
     ORDER BY messages.created_at ASC, messages.id ASC`
  ).all(patientId);
}

function insertMessage(patientId, sender, doctorId, body) {
  const result = db.prepare(
    `INSERT INTO messages (patient_id, sender, doctor_id, body) VALUES (?, ?, ?, ?)`
  ).run(patientId, sender, doctorId, body.slice(0, 2000));
  return db.prepare(`${MESSAGE_SELECT} WHERE messages.id = ?`).get(Number(result.lastInsertRowid));
}

/// The patient's own thread, reached with their card (or phone session).
app.get('/api/patients/token/:token/messages', lookupLimiter, (req, res) => {
  const patient = resolvePatientFromReq(req);
  if (!patient) {
    return res.status(404).json({ error: 'No patient found for this card' });
  }
  res.json(messageThread(patient.id));
});

app.post('/api/patients/token/:token/messages', lookupLimiter, (req, res) => {
  const patient = resolvePatientFromReq(req);
  if (!patient) {
    return res.status(404).json({ error: 'No patient found for this card' });
  }
  const body = optionalText(req.body.body);
  if (!body) {
    return res.status(400).json({ error: 'Message cannot be empty' });
  }
  res.status(201).json(insertMessage(patient.id, 'patient', null, body));
});

/// The same thread from the doctor's side, by patient id.
app.get('/api/patients/:id/messages', requireDoctor, (req, res) => {
  res.json(messageThread(req.params.id));
});

app.post('/api/patients/:id/messages', requireDoctor, (req, res) => {
  const patient = db.prepare(`SELECT id FROM patients WHERE id = ?`).get(req.params.id);
  if (!patient) {
    return res.status(404).json({ error: 'Patient not found' });
  }
  const body = optionalText(req.body.body);
  if (!body) {
    return res.status(400).json({ error: 'Message cannot be empty' });
  }
  res.status(201).json(insertMessage(patient.id, 'doctor', req.doctor.id, body));
});

// --- Clinics and appointments ---
//
// Booking follows the same trust rule as readings: possession of the card is
// the patient's credential, so a patient can book, view and cancel their own
// appointments without a doctor login. A booking lands as `requested` and
// holds its slot until a doctor confirms or rejects it.

const HELD_PLACEHOLDERS = HELD_STATUSES.map(() => '?').join(', ');

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

function appointmentById(id) {
  return db.prepare(`${APPOINTMENT_SELECT} WHERE appointments.id = ?`).get(id);
}

function activeClinic(id) {
  // Guarded: a missing or non-numeric clinicId must read as "no such clinic",
  // not blow up when bound as a query parameter.
  const numeric = Number(id);
  if (!Number.isInteger(numeric)) return null;
  return db.prepare(
    `SELECT * FROM clinics WHERE id = ? AND status = 'active'`
  ).get(numeric) || null;
}

/// Trim a free-text field from an untrusted body, whatever type it arrives as.
function optionalText(value) {
  return typeof value === 'string' && value.trim() ? value.trim() : null;
}

/// Whole years between a "YYYY-MM-DD" date of birth and [today], or null if the
/// value is missing/unparseable. Used for the dashboard's age demographics.
function ageFrom(dob, today = new Date()) {
  if (typeof dob !== 'string' || !/^\d{4}-\d{2}-\d{2}/.test(dob)) return null;
  const born = new Date(`${dob.slice(0, 10)}T00:00:00`);
  if (Number.isNaN(born.getTime())) return null;
  let age = today.getFullYear() - born.getFullYear();
  const m = today.getMonth() - born.getMonth();
  if (m < 0 || (m === 0 && today.getDate() < born.getDate())) age -= 1;
  return age >= 0 ? age : null;
}

/// Percentage change from [previous] to [current], rounded. Null when there is
/// no baseline, so a tile can simply omit the arrow rather than divide by zero.
function pctDelta(current, previous) {
  if (!previous) return null;
  return Math.round(((current - previous) / previous) * 100);
}

/// The "HH:MM" times already held by live appointments at a clinic on a
/// date. Scoped to one doctor's day when `doctorId` is given, so two doctors
/// at the same clinic don't block each other's slots — but doctor-less
/// (legacy/unassigned) appointments still count against every doctor, since
/// they occupy the clinic's one shared pool of capacity and no partial index
/// spans both categories.
function heldTimes(clinicId, dateStr, doctorId) {
  const doctorClause = doctorId ? ' AND (doctor_id = ? OR doctor_id IS NULL)' : '';
  const params = [clinicId, `${dateStr}%`, ...HELD_STATUSES];
  if (doctorId) params.push(doctorId);
  return db.prepare(
    `SELECT starts_at FROM appointments
     WHERE clinic_id = ? AND starts_at LIKE ? AND status IN (${HELD_PLACEHOLDERS})${doctorClause}`
  )
    .all(...params)
    .map((row) => row.starts_at.slice(11, 16));
}

/// Registered facilities a patient can book into. Open to everyone: you must
/// be able to browse clinics before you hold anything to identify yourself with.
app.get('/api/clinics', (_req, res) => {
  res.json(db.prepare(
    `SELECT * FROM clinics WHERE status = 'active' ORDER BY kind, name`
  ).all());
});

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

app.post('/api/clinics', requireDoctor, (req, res) => {
  const fields = {
    name: req.body.name,
    kind: req.body.kind,
    opens_at: req.body.opensAt,
    closes_at: req.body.closesAt,
    slot_minutes: req.body.slotMinutes ?? 30,
    open_days: req.body.openDays ?? '1,2,3,4,5',
  };

  const problem = clinicError(fields);
  if (problem) return res.status(400).json({ error: problem });

  const result = db.prepare(
    `INSERT INTO clinics (name, kind, address, phone, opens_at, closes_at, slot_minutes, open_days)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
  ).run(
    String(fields.name).trim(),
    fields.kind,
    optionalText(req.body.address),
    optionalText(req.body.phone),
    fields.opens_at,
    fields.closes_at,
    Number(fields.slot_minutes),
    String(fields.open_days),
  );

  res.status(201).json(
    db.prepare(`SELECT * FROM clinics WHERE id = ?`).get(Number(result.lastInsertRowid))
  );
});

/// True when the clinic+time is already held by an appointment on the *other*
/// side of the doctor_id divide — a doctor-less booking when we're placing a
/// doctor-assigned one, or vice versa.
///
/// The two partial unique indexes each police only their own half
/// (`doctor_id IS NULL` / `IS NOT NULL`), so neither one catches a collision
/// that crosses between them. Without this check the pair would both land and
/// the clinic would be double-booked at the same minute. Safe to check-then-
/// write: `node:sqlite` is synchronous, so nothing else runs between this
/// query and the write that follows it.
function crossCategoryHeld(clinicId, startsAt, doctorId) {
  return db.prepare(
    doctorId
      ? `SELECT 1 FROM appointments WHERE clinic_id = ? AND starts_at = ? AND doctor_id IS NULL AND status IN (${HELD_PLACEHOLDERS})`
      : `SELECT 1 FROM appointments WHERE clinic_id = ? AND starts_at = ? AND doctor_id IS NOT NULL AND status IN (${HELD_PLACEHOLDERS})`
  ).get(clinicId, startsAt, ...HELD_STATUSES);
}

/// Bookable slots at a clinic on a date: its opening hours, minus the slots
/// already held, minus anything now in the past.
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

  if (crossCategoryHeld(clinic.id, startsAt, doctorId)) {
    return res.status(409).json({
      error: 'That slot has just been taken. Please choose another time.',
    });
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
    // Losing the race for a slot is an ordinary outcome, not a server fault:
    // the other patient's INSERT simply landed first.
    if (String(err.message).includes('UNIQUE')) {
      return res.status(409).json({
        error: 'That slot has just been taken. Please choose another time.',
      });
    }
    throw err;
  }

  // A doctor may book on a patient's behalf; if so, attribute it to them.
  const doctor = doctorFromRequest(req);
  logAudit(patient.id, doctor ? doctor.id : null, 'appointment_request',
    `Requested ${startsAt} at ${clinic.name}`);

  res.status(201).json(appointmentById(Number(result.lastInsertRowid)));
});

/// A patient's own appointments, reached with their card. Soonest first.
app.get('/api/patients/token/:token/appointments', lookupLimiter, (req, res) => {
  const patient = resolvePatientFromReq(req);
  if (!patient) {
    return res.status(404).json({ error: 'No patient found for this card' });
  }
  res.json(db.prepare(
    `${APPOINTMENT_SELECT} WHERE appointments.patient_id = ?
     ORDER BY appointments.starts_at DESC`
  ).all(patient.id));
});

app.post('/api/patients/token/:token/appointments/:id/cancel', lookupLimiter, (req, res) => {
  const patient = resolvePatientFromReq(req);
  if (!patient) {
    return res.status(404).json({ error: 'No patient found for this card' });
  }

  // Scoped to the cardholder: presenting one card never cancels another
  // patient's appointment, even with a valid appointment id.
  const appointment = db.prepare(
    `SELECT * FROM appointments WHERE id = ? AND patient_id = ?`
  ).get(req.params.id, patient.id);

  if (!appointment) {
    return res.status(404).json({ error: 'Appointment not found' });
  }
  if (!HELD_STATUSES.includes(appointment.status)) {
    return res.status(409).json({
      error: `This appointment is already ${appointment.status}.`,
    });
  }

  db.prepare(
    `UPDATE appointments SET status = 'cancelled', updated_at = datetime('now')
     WHERE id = ?`
  ).run(appointment.id);

  logAudit(patient.id, null, 'appointment_cancel',
    `Cancelled appointment on ${appointment.starts_at}`);
  res.json(appointmentById(appointment.id));
});

/// Doctor-side view of the record, alongside notes and readings.
app.get('/api/patients/:id/appointments', (req, res) => {
  res.json(db.prepare(
    `${APPOINTMENT_SELECT} WHERE appointments.patient_id = ?
     ORDER BY appointments.starts_at DESC`
  ).all(req.params.id));
});

/// The approval queue. Defaults to what needs a decision.
app.get('/api/appointments', requireDoctor, (req, res) => {
  const status = req.query.status ?? 'requested';
  if (!STATUSES.includes(status)) {
    return res.status(400).json({
      error: `status must be one of: ${STATUSES.join(', ')}`,
    });
  }
  res.json(db.prepare(
    `${APPOINTMENT_SELECT} WHERE appointments.status = ?
     ORDER BY appointments.starts_at ASC`
  ).all(status));
});

/// One call powering the doctor's landing dashboard, so the app makes a single
/// round trip instead of a fan-out. Every figure is derived from real rows:
/// appointments (by status and day), patient registrations, and doctor-issued
/// medications (which are, in effect, prescriptions).
app.get('/api/doctor/dashboard', requireDoctor, (req, res) => {
  const today = db.prepare(`SELECT date('now', 'localtime') AS d`).get().d;
  const todayDate = new Date(`${today}T00:00:00`);

  // Today's schedule rail: live bookings for today, in order.
  const todaysAppointments = db.prepare(
    `${APPOINTMENT_SELECT}
     WHERE substr(appointments.starts_at, 1, 10) = ?
       AND appointments.status IN ('requested', 'confirmed', 'reschedule_requested', 'completed')
     ORDER BY appointments.starts_at ASC`
  ).all(today);

  // KPI: patients registered this calendar month vs last month. created_at is
  // stored UTC, so it is compared against UTC months.
  const patientsThisMonth = db.prepare(
    `SELECT COUNT(*) AS n FROM patients WHERE substr(created_at, 1, 7) = strftime('%Y-%m', 'now')`
  ).get().n;
  const patientsLastMonth = db.prepare(
    `SELECT COUNT(*) AS n FROM patients WHERE substr(created_at, 1, 7) = strftime('%Y-%m', 'now', '-1 month')`
  ).get().n;

  // KPI: prescriptions (doctor-issued medications) in the last 7 days vs prior 7.
  const prescriptionsThisWeek = db.prepare(
    `SELECT COUNT(*) AS n FROM medications
     WHERE source = 'doctor' AND created_at >= datetime('now', '-7 days')`
  ).get().n;
  const prescriptionsPrevWeek = db.prepare(
    `SELECT COUNT(*) AS n FROM medications
     WHERE source = 'doctor'
       AND created_at >= datetime('now', '-14 days')
       AND created_at <  datetime('now', '-7 days')`
  ).get().n;

  // KPI (replaces "satisfaction", which has no data source): confirmed
  // appointments still to come in the next 7 days.
  const confirmedThisWeek = db.prepare(
    `SELECT COUNT(*) AS n FROM appointments
     WHERE status = 'confirmed'
       AND starts_at >= datetime('now', 'localtime')
       AND starts_at <  datetime('now', 'localtime', '+7 days')`
  ).get().n;

  // Demographics over the registered population.
  const population = db.prepare(`SELECT date_of_birth, gender FROM patients`).all();
  const ageBuckets = { '0-12': 0, '13-18': 0, '19-35': 0, '36-50': 0, '51-65': 0, '65+': 0 };
  const gender = { female: 0, male: 0, unknown: 0 };
  for (const p of population) {
    const g = String(p.gender || '').toLowerCase();
    if (g === 'female' || g === 'f') gender.female += 1;
    else if (g === 'male' || g === 'm') gender.male += 1;
    else gender.unknown += 1;

    const age = ageFrom(p.date_of_birth, todayDate);
    if (age == null) continue;
    if (age <= 12) ageBuckets['0-12'] += 1;
    else if (age <= 18) ageBuckets['13-18'] += 1;
    else if (age <= 35) ageBuckets['19-35'] += 1;
    else if (age <= 50) ageBuckets['36-50'] += 1;
    else if (age <= 65) ageBuckets['51-65'] += 1;
    else ageBuckets['65+'] += 1;
  }

  // Appointments this month: a completed/cancelled pair per day (starts_at is
  // local wall clock, so the month is taken in local time to match).
  const monthRows = db.prepare(
    `SELECT substr(starts_at, 1, 10) AS day,
            SUM(status = 'completed') AS completed,
            SUM(status IN ('cancelled', 'rejected')) AS cancelled
     FROM appointments
     WHERE substr(starts_at, 1, 7) = strftime('%Y-%m', 'now', 'localtime')
     GROUP BY day ORDER BY day ASC`
  ).all();
  const monthCompleted = monthRows.reduce((s, r) => s + Number(r.completed), 0);
  const monthCancelled = monthRows.reduce((s, r) => s + Number(r.cancelled), 0);

  // Requests still waiting on a doctor decision, regardless of month —
  // surfaced as a nudge alongside the month's tallies.
  const pendingRequests = db.prepare(
    `SELECT COUNT(*) AS n FROM appointments WHERE status IN ('requested', 'reschedule_requested')`
  ).get().n;

  // New patients: most recent registrations, tagged with the reason for their
  // latest booking (if any) as a one-line "why".
  const newPatients = db.prepare(
    `SELECT id, full_name, date_of_birth, created_at FROM patients
     ORDER BY created_at DESC LIMIT 4`
  ).all().map((p) => {
    const lastAppt = db.prepare(
      `SELECT reason FROM appointments WHERE patient_id = ? ORDER BY starts_at DESC LIMIT 1`
    ).get(p.id);
    return {
      id: p.id,
      full_name: p.full_name,
      age: ageFrom(p.date_of_birth, todayDate),
      last_visit: p.created_at,
      reason: lastAppt?.reason ?? null,
    };
  });

  res.json({
    today: { count: todaysAppointments.length, appointments: todaysAppointments },
    kpis: {
      todaysAppointments: todaysAppointments.length,
      patientsThisMonth,
      patientsDeltaPct: pctDelta(patientsThisMonth, patientsLastMonth),
      prescriptionsThisWeek,
      prescriptionsDeltaPct: pctDelta(prescriptionsThisWeek, prescriptionsPrevWeek),
      confirmedThisWeek,
    },
    demographics: { total: population.length, gender, ageBuckets },
    appointmentsThisMonth: {
      completed: monthCompleted,
      cancelled: monthCancelled,
      pending: pendingRequests,
      series: monthRows.map((r) => ({
        day: r.day,
        completed: Number(r.completed),
        cancelled: Number(r.cancelled),
      })),
    },
    newPatients,
  });
});

/// Practice analytics for the Reports page: appointment volume over the last
/// eight weeks, the most common diagnoses, and the split of appointments by
/// status. All doctor-only, all from real rows.
app.get('/api/doctor/reports', requireDoctor, (req, res) => {
  const today = new Date(
    `${db.prepare(`SELECT date('now', 'localtime') AS d`).get().d}T00:00:00`
  );
  // Monday of the current week (ISO: Monday = 0).
  const mondayOffset = (today.getDay() + 6) % 7;
  const thisMonday = new Date(today);
  thisMonday.setDate(today.getDate() - mondayOffset);

  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const weeks = [];
  for (let i = 7; i >= 0; i -= 1) {
    const start = new Date(thisMonday);
    start.setDate(thisMonday.getDate() - i * 7);
    const end = new Date(start);
    end.setDate(start.getDate() + 7);
    weeks.push({
      start,
      end,
      label: `${start.getDate()} ${months[start.getMonth()]}`,
      completed: 0,
      cancelled: 0,
      total: 0,
    });
  }

  const recent = db.prepare(
    `SELECT substr(starts_at, 1, 10) AS day, status FROM appointments
     WHERE starts_at >= datetime('now', 'localtime', '-56 days')`
  ).all();
  for (const r of recent) {
    const d = new Date(`${r.day}T00:00:00`);
    const w = weeks.find((wk) => d >= wk.start && d < wk.end);
    if (!w) continue;
    w.total += 1;
    if (r.status === 'completed') w.completed += 1;
    else if (r.status === 'cancelled' || r.status === 'rejected') w.cancelled += 1;
  }

  // Most common diagnoses, deduped case-insensitively but shown in their
  // recorded casing.
  const topConditions = db.prepare(
    `SELECT condition_name AS name, COUNT(*) AS count FROM medical_history
     WHERE condition_name IS NOT NULL AND TRIM(condition_name) <> ''
     GROUP BY LOWER(TRIM(condition_name))
     ORDER BY count DESC, name ASC LIMIT 6`
  ).all();

  const statusBreakdown = db.prepare(
    `SELECT status, COUNT(*) AS count FROM appointments GROUP BY status`
  ).all();

  res.json({
    appointmentsByWeek: weeks.map((w) => ({
      label: w.label,
      completed: w.completed,
      cancelled: w.cancelled,
      total: w.total,
    })),
    topConditions,
    statusBreakdown,
  });
});

/// Confirm, reject, cancel or complete a booking. Doctors only — this is the
/// approval step that a patient's request waits on.
app.post('/api/appointments/:id/decision', requireDoctor, (req, res) => {
  const appointment = db.prepare(
    `SELECT * FROM appointments WHERE id = ?`
  ).get(req.params.id);

  if (!appointment) {
    return res.status(404).json({ error: 'Appointment not found' });
  }

  const { status, note } = req.body;
  if (!DOCTOR_DECISIONS.includes(status)) {
    return res.status(400).json({
      error: `status must be one of: ${DOCTOR_DECISIONS.join(', ')}`,
    });
  }

  // A single table decides every legal move, so re-confirming, un-rejecting or
  // completing an unconfirmed booking are all rejected the same way.
  const allowed = ALLOWED_TRANSITIONS[appointment.status] ?? [];
  if (!allowed.includes(status)) {
    return res.status(409).json({
      error: `An appointment that is ${appointment.status} cannot be marked ${status}.`,
    });
  }

  db.prepare(
    `UPDATE appointments
     SET status = ?, decided_by = ?, decided_at = datetime('now'),
         decision_note = ?, updated_at = datetime('now')
     WHERE id = ?`
  ).run(status, req.doctor.id, optionalText(note), appointment.id);

  logAudit(appointment.patient_id, req.doctor.id, `appointment_${status}`,
    `Appointment on ${appointment.starts_at} marked ${status}`);
  res.json(appointmentById(appointment.id));
});

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

  // The target slot may be occupied by an appointment on the other side of
  // the doctor_id divide, which neither partial unique index would catch.
  if (crossCategoryHeld(appointment.clinic_id, appointment.proposed_starts_at, appointment.doctor_id)) {
    return { status: 409, error: 'That slot has just been taken. Please choose another time.' };
  }

  try {
    if (doctorId) {
      // A doctor is the one accepting, so they become the deciding doctor.
      db.prepare(
        `UPDATE appointments
         SET status = 'confirmed', starts_at = proposed_starts_at,
             proposed_starts_at = NULL, proposed_by = NULL, reschedule_reason = NULL,
             decided_by = ?, decided_at = datetime('now'), updated_at = datetime('now')
         WHERE id = ?`
      ).run(doctorId, appointment.id);
    } else {
      // A patient accepted a doctor-proposed move. decided_by already records
      // the doctor who originally confirmed this appointment — leave it (and
      // decided_at) alone rather than blanking that history out.
      db.prepare(
        `UPDATE appointments
         SET status = 'confirmed', starts_at = proposed_starts_at,
             proposed_starts_at = NULL, proposed_by = NULL, reschedule_reason = NULL,
             updated_at = datetime('now')
         WHERE id = ?`
      ).run(appointment.id);
    }
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

  // The candidate window runs forward from *today*, not from the appointment's
  // own date: someone rescheduling usually wants an earlier or same-day slot,
  // and anchoring on the original date would only ever offer later ones. It is
  // also capped to the booking horizon, so nothing we suggest would be
  // rejected by `bookingError` if the patient actually proposed it.
  const origStartsAt = appointment.starts_at;
  const [origDate] = origStartsAt.split(' ');
  const now = new Date();
  const start = new Date(`${toDateString(now)}T00:00:00`);
  const lastOffset = Math.min(13, MAX_ADVANCE_DAYS);
  const sameDayBookedTimesByDate = {};
  const candidates = [];
  for (let i = 0; i <= lastOffset; i++) {
    const d = new Date(start);
    d.setDate(d.getDate() + i);
    const dateStr = toDateString(d);
    const taken = heldTimes(clinic.id, dateStr, appointment.doctor_id || undefined);
    sameDayBookedTimesByDate[dateStr] = taken;
    for (const time of availableSlots(clinic, dateStr, taken, now)) {
      // Only this appointment's own slot is off the table on its own day —
      // the rest of that day is fair game. (It is normally filtered out by
      // `taken` anyway, since a live appointment holds its own slot; this is
      // the explicit guarantee that we never suggest moving a time to itself.)
      if (dateStr === origDate && `${dateStr} ${time}` === origStartsAt) continue;
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
    now,
    limit: 5,
  });

  const aiSuggestions = await rationalizeCandidates({
    originalStartsAt: appointment.starts_at,
    urgencyTag: tag,
    candidates: ranked,
  });

  // Rationale is matched by slot time, not by position, regardless of whether
  // the reorder is trusted: nothing in the schema stops Gemini from coming up
  // short on some slots even when it gets the full set right, and a
  // positional lookup would quietly attach the wrong reason to a slot.
  const aiByStartsAt = new Map((aiSuggestions ?? []).map((s) => [s.startsAt, s.rationale]));

  // Gemini may reorder the candidates by its own judgement, but never changes
  // *which* slots are offered — reschedule.js's set stays authoritative;
  // see gemini.js's orderedStartsAts for the exact-permutation check.
  const rankedByStartsAt = new Map(ranked.map((r) => [r.startsAt, r]));
  const order = orderedStartsAts(ranked, aiSuggestions);

  return order.map((startsAt) => {
    const r = rankedByStartsAt.get(startsAt);
    return {
      startsAt: r.startsAt,
      patientFit: r.patientFit,
      clinicFit: r.clinicFit,
      rationale: aiByStartsAt.get(r.startsAt) ?? templatedRationale(r),
    };
  });
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

// --- NFC tap broadcast ---
//
// reader.js runs as a separate process from the app — it's the only thing
// actually talking to the physical reader — so a tap has to reach the app
// some other way than a function call. This is a minimal pub/sub bridge:
// reader.js posts each token it reads here, and every connected app
// instance (there's normally just one, running on the same machine) gets
// it pushed over Server-Sent Events. The app then does exactly what typing
// the token into "Read a card" would do — this endpoint carries no more
// trust than that manual entry already has.
const tapClients = new Set();

app.get('/api/taps/stream', (req, res) => {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
  });
  res.write(':ok\n\n'); // comment line, just to flush headers to the client immediately
  tapClients.add(res);
  req.on('close', () => tapClients.delete(res));
});

app.post('/api/taps', lookupLimiter, (req, res) => {
  const { token } = req.body;
  if (typeof token !== 'string' || !token) {
    return res.status(400).json({ error: 'token is required' });
  }
  const payload = `data: ${JSON.stringify({ token })}\n\n`;
  for (const client of tapClients) client.write(payload);
  res.json({ delivered: tapClients.size });
});

// --- Emergency view ---
//
// A stripped-down, unauthenticated HTML page for a card token — meant to be
// opened by a stranger's phone (a first responder with no MedThru app
// installed) via a URI record written to the card, not by the MedThru app
// itself. Deliberately narrower than the full record: only what a
// responder needs in the first few minutes, not the whole clinical history.
// Same trust model as every other card-token route here: physical
// possession of the card is the credential, no login required.

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;',
  }[c]));
}

function emergencyPage({ patient, allergies, medications, contacts }) {
  const body = !patient
    ? `<p class="muted">This card isn't registered to a patient.</p>`
    : `
      <h1>${escapeHtml(patient.full_name)}</h1>
      <p class="muted">DOB ${escapeHtml(patient.date_of_birth || 'Unknown')}</p>

      <div class="tile">
        <span class="label">Blood type</span>
        <span class="value">${escapeHtml(patient.blood_type || 'Unknown')}</span>
      </div>

      <section>
        <h2>Allergies</h2>
        ${
          allergies.length === 0
            ? '<p class="muted">None recorded.</p>'
            : `<ul>${allergies
                .map(
                  (a) =>
                    `<li><strong>${escapeHtml(a.allergen)}</strong>${
                      a.reaction ? ` — ${escapeHtml(a.reaction)}` : ''
                    }${a.severity ? ` <span class="tag">${escapeHtml(a.severity)}</span>` : ''}</li>`
                )
                .join('')}</ul>`
        }
      </section>

      <section>
        <h2>Current medications</h2>
        ${
          medications.length === 0
            ? '<p class="muted">None recorded.</p>'
            : `<ul>${medications
                .map(
                  (m) =>
                    `<li><strong>${escapeHtml(m.name)}</strong>${
                      m.dosage ? ` — ${escapeHtml(m.dosage)}` : ''
                    }${m.frequency ? ` (${escapeHtml(m.frequency)})` : ''}</li>`
                )
                .join('')}</ul>`
        }
      </section>

      <section>
        <h2>Emergency contacts</h2>
        ${
          contacts.length === 0
            ? '<p class="muted">None recorded.</p>'
            : `<ul>${contacts
                .map(
                  (c) =>
                    `<li><strong>${escapeHtml(c.name)}</strong>${
                      c.relationship ? ` (${escapeHtml(c.relationship)})` : ''
                    } — <a href="tel:${escapeHtml(c.phone)}">${escapeHtml(c.phone)}</a></li>`
                )
                .join('')}</ul>`
        }
      </section>

      <p class="disclaimer">
        Self-reported and clinician-entered information only — not a
        diagnosis and not a substitute for a full clinical record.
      </p>
    `;

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MedThru — Emergency information</title>
<style>
  :root { color-scheme: light dark; }
  body {
    font-family: -apple-system, Roboto, Segoe UI, sans-serif;
    max-width: 480px;
    margin: 0 auto;
    padding: 24px 20px 48px;
    line-height: 1.45;
  }
  h1 { font-size: 26px; margin-bottom: 2px; }
  h2 { font-size: 15px; text-transform: uppercase; letter-spacing: 0.04em;
       opacity: 0.65; margin: 28px 0 8px; }
  .muted { opacity: 0.65; margin-top: 0; }
  .tile {
    display: flex; justify-content: space-between; align-items: baseline;
    border: 1px solid currentColor; border-radius: 12px;
    padding: 14px 16px; margin: 16px 0; opacity: 0.92;
  }
  .tile .label { font-size: 13px; opacity: 0.7; }
  .tile .value { font-size: 22px; font-weight: 700; }
  ul { padding-left: 20px; margin: 0; }
  li { margin-bottom: 6px; }
  .tag {
    font-size: 11px; border: 1px solid currentColor; border-radius: 999px;
    padding: 1px 8px; opacity: 0.75; margin-left: 4px;
  }
  a { color: inherit; }
  .disclaimer { font-size: 12px; opacity: 0.6; margin-top: 32px; }
</style>
</head>
<body>
${body}
</body>
</html>`;
}

app.get('/emergency/:token', lookupLimiter, (req, res) => {
  const patient = patientForCardToken(req.params.token);
  if (!patient) {
    return res.status(404).type('html').send(emergencyPage({}));
  }

  const allergies = db.prepare(
    `SELECT allergen, reaction, severity FROM allergies WHERE patient_id = ? ORDER BY created_at DESC`
  ).all(patient.id);
  const medications = db.prepare(
    `SELECT name, dosage, frequency FROM medications WHERE patient_id = ?
     AND (end_date IS NULL OR end_date >= date('now')) ORDER BY created_at DESC`
  ).all(patient.id);
  const contacts = db.prepare(
    `SELECT name, phone, relationship FROM emergency_contacts WHERE patient_id = ? ORDER BY created_at DESC`
  ).all(patient.id);

  logAudit(patient.id, null, 'emergency_view', null);
  res.type('html').send(emergencyPage({ patient, allergies, medications, contacts }));
});

const PORT = 3000;
app.listen(PORT, () => {
  console.log(`MedThru API listening on http://localhost:${PORT}`);
});
