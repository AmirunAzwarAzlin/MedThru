// Realistic vital-sign and anthropometry ranges by age/gender, shared by the
// demo-data seeder and the vitals backfill script so both generate values
// from the same clinically-plausible bands.

function randInt(min, max) {
  return min + Math.floor(Math.random() * (max - min + 1));
}

function ageFromDob(dob) {
  if (!dob) return null;
  const birth = new Date(dob);
  if (Number.isNaN(birth.getTime())) return null;
  const diffMs = Date.now() - birth.getTime();
  return Math.floor(diffMs / (365.25 * 86400000));
}

/// One realistic {type, value, unit} reading per vital/anthropometry
/// category, for a patient of the given date of birth and gender. Unknown
/// dob/gender fall back to general adult ranges.
function generateVitalReadings(dob, gender) {
  const age = ageFromDob(dob);
  const male = gender === 'male';

  let heightCm, weightKg, heartRate, bpSys, bpDia;
  const temperature = (randInt(361, 372) / 10).toFixed(1);

  if (age !== null && age < 1) {
    heightCm = randInt(50, 75);
    weightKg = randInt(3, 10);
    heartRate = randInt(100, 160);
    bpSys = randInt(70, 100);
    bpDia = randInt(40, 65);
  } else if (age !== null && age < 3) {
    heightCm = randInt(75, 95);
    weightKg = randInt(9, 15);
    heartRate = randInt(90, 150);
    bpSys = randInt(80, 105);
    bpDia = randInt(45, 70);
  } else if (age !== null && age < 13) {
    heightCm = randInt(95, 150);
    weightKg = randInt(14, 45);
    heartRate = randInt(70, 120);
    bpSys = randInt(90, 115);
    bpDia = randInt(55, 75);
  } else if (age !== null && age < 18) {
    heightCm = randInt(150, 180);
    weightKg = randInt(40, 75);
    heartRate = randInt(60, 100);
    bpSys = randInt(100, 125);
    bpDia = randInt(60, 80);
  } else {
    // Adult (or unknown age): gender-shaped ranges, wider BP band past 60.
    heightCm = male ? randInt(160, 185) : randInt(150, 170);
    weightKg = male ? randInt(55, 95) : randInt(45, 80);
    heartRate = randInt(60, 100);
    const senior = age !== null && age >= 60;
    bpSys = senior ? randInt(110, 150) : randInt(100, 140);
    bpDia = senior ? randInt(70, 95) : randInt(65, 90);
  }

  return [
    { type: 'blood_pressure_systolic', value: bpSys, unit: 'mmHg' },
    { type: 'blood_pressure_diastolic', value: bpDia, unit: 'mmHg' },
    { type: 'heart_rate', value: heartRate, unit: 'bpm' },
    { type: 'temperature', value: Number(temperature), unit: '°C' },
    { type: 'weight', value: weightKg, unit: 'kg' },
    { type: 'height', value: heightCm, unit: 'cm' },
  ];
}

module.exports = { generateVitalReadings, ageFromDob };
