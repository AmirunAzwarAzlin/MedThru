const API_BASE = process.env.MEDTHRU_API || 'http://localhost:3000/api';

async function lookupPatientByToken(token) {
  const res = await fetch(`${API_BASE}/patients/token/${encodeURIComponent(token)}`);

  if (res.status === 404) {
    console.log(`No patient registered for card ${token}`);
    return null;
  }
  if (!res.ok) {
    console.error(`Lookup failed (${res.status}): ${await res.text()}`);
    return null;
  }

  const patient = await res.json();
  console.log('--- Patient record ---');
  console.log(`Name:        ${patient.full_name}`);
  console.log(`DOB:         ${patient.date_of_birth ?? '-'}`);
  console.log(`Blood type:  ${patient.blood_type ?? '-'}`);
  console.log(`Allergies:   ${patient.allergies ?? '-'}`);
  console.log(`Medications: ${patient.medications ?? '-'}`);
  console.log(`Conditions:  ${patient.conditions ?? '-'}`);
  console.log(`Emergency:   ${patient.emergency_contact_name ?? '-'} (${patient.emergency_contact_phone ?? '-'})`);
  console.log('-----------------------');
  return patient;
}

module.exports = { lookupPatientByToken };
