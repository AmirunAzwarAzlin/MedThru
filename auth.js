const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');

// Dev-only fallback secret. Must be overridden via env var before this
// touches real patient data.
const JWT_SECRET = process.env.JWT_SECRET || 'dev-secret-change-me';

function hashPassword(password) {
  return bcrypt.hashSync(password, 10);
}

function verifyPassword(password, hash) {
  return bcrypt.compareSync(password, hash);
}

function signDoctorToken(doctor) {
  return jwt.sign(
    { sub: doctor.id, email: doctor.email, role: 'doctor' },
    JWT_SECRET,
    { expiresIn: '12h' },
  );
}

// Rejects a patient token presented where a doctor is expected, even though
// both are just JWTs signed with the same secret and could share a `sub`.
function verifyDoctorToken(token) {
  const payload = jwt.verify(token, JWT_SECRET);
  if (payload.role !== 'doctor') throw new Error('Not a doctor token');
  return payload;
}

// A patient's alternative to presenting their card: phone + password, set up
// once while the card is in hand. Scoped with role: 'patient' so it can never
// be mistaken for a doctor token even if the ids collide.
function signPatientToken(patient) {
  return jwt.sign(
    { sub: patient.id, role: 'patient' },
    JWT_SECRET,
    { expiresIn: '12h' },
  );
}

function verifyPatientToken(token) {
  const payload = jwt.verify(token, JWT_SECRET);
  if (payload.role !== 'patient') throw new Error('Not a patient token');
  return payload;
}

module.exports = {
  hashPassword,
  verifyPassword,
  signDoctorToken,
  verifyDoctorToken,
  signPatientToken,
  verifyPatientToken,
};
