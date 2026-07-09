const { lookupPatientByToken } = require('./lookup');

const token = process.argv[2];
if (!token) {
  console.error('Usage: node simulate-tap.js <card-token>');
  process.exit(1);
}

console.log(`Simulating card tap, UID: ${token}`);
lookupPatientByToken(token);
