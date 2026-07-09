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
  return jwt.sign({ sub: doctor.id, email: doctor.email }, JWT_SECRET, { expiresIn: '12h' });
}

function verifyDoctorToken(token) {
  return jwt.verify(token, JWT_SECRET);
}

module.exports = { hashPassword, verifyPassword, signDoctorToken, verifyDoctorToken };
