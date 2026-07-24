/// Appointment scheduling rules.
///
/// Kept out of server.js so the slot maths stands on its own. Times here are
/// clinic-local wall clock ("2026-07-20 10:00") — the time a patient would
/// read off a signboard — never UTC. Storing what the clinic means avoids a
/// timezone conversion at every layer for an app that runs in one country.

/// Statuses that occupy a slot. A request holds its slot while it waits for a
/// doctor, so nobody else is offered it; cancelling or rejecting frees it
/// again with no extra bookkeeping.
const HELD_STATUSES = ['requested', 'confirmed'];

const STATUSES = [
  'requested', 'confirmed', 'rejected', 'cancelled', 'completed',
];

/// Statuses a doctor may move a live appointment to.
const DOCTOR_DECISIONS = ['confirmed', 'rejected', 'cancelled', 'completed'];

/// Which decisions are legal from each live status. A fresh request can be
/// ruled on; once confirmed it can only be seen through or called off — it
/// cannot be "confirmed" again or bounced back to rejected. Anything not
/// listed here (rejected, cancelled, completed) is final.
const ALLOWED_TRANSITIONS = {
  requested: ['confirmed', 'rejected', 'cancelled'],
  confirmed: ['cancelled', 'completed'],
};

const KINDS = ['hospital', 'clinic'];

/// How far ahead a patient may book.
const MAX_ADVANCE_DAYS = 90;

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;

function pad(n) {
  return String(n).padStart(2, '0');
}

function toDateString(d) {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

/// Round-trips through Date, so impossible calendar dates like 2026-02-31
/// (which Date would silently roll into March) are rejected rather than shifted.
function isValidDate(value) {
  if (typeof value !== 'string' || !DATE_RE.test(value)) return false;
  const d = new Date(`${value}T00:00:00`);
  return !Number.isNaN(d.getTime()) && toDateString(d) === value;
}

function minutesOf(hhmm) {
  const [h, m] = hhmm.split(':').map(Number);
  return h * 60 + m;
}

function hhmmOf(mins) {
  return `${pad(Math.floor(mins / 60))}:${pad(mins % 60)}`;
}

/// ISO weekday: 1 = Monday … 7 = Sunday, matching clinics.open_days.
function isoWeekday(dateStr) {
  const day = new Date(`${dateStr}T00:00:00`).getDay(); // 0 = Sunday
  return day === 0 ? 7 : day;
}

function openDays(clinic) {
  return String(clinic.open_days)
    .split(',')
    .map((s) => Number(s.trim()))
    .filter((n) => Number.isInteger(n) && n >= 1 && n <= 7);
}

function isOpenOn(clinic, dateStr) {
  return openDays(clinic).includes(isoWeekday(dateStr));
}

/// Accept "2026-07-20T10:00", "2026-07-20 10:00:00" etc. and reduce them to the
/// one stored form, so the same instant never lands in the table twice under
/// two spellings — the unique index that blocks double-booking compares text.
function normalizeStartsAt(value) {
  if (typeof value !== 'string') return '';
  return value.trim().replace('T', ' ').slice(0, 16);
}

/// Every slot a clinic runs on a date, ignoring what is already booked.
/// A slot must finish before closing time, so a 30-minute slot at a clinic
/// closing at 17:00 is last offered at 16:30.
function slotsForDate(clinic, dateStr) {
  if (!isValidDate(dateStr) || !isOpenOn(clinic, dateStr)) return [];
  const step = Number(clinic.slot_minutes);
  if (!Number.isInteger(step) || step <= 0) return [];

  const close = minutesOf(clinic.closes_at);
  const slots = [];
  for (let t = minutesOf(clinic.opens_at); t + step <= close; t += step) {
    slots.push(hhmmOf(t));
  }
  return slots;
}

/// Slots a patient can still take: not already held, and not in the past.
/// `taken` is the list of "HH:MM" times held by live appointments that day.
function availableSlots(clinic, dateStr, taken, now = new Date()) {
  const held = new Set(taken);
  return slotsForDate(clinic, dateStr).filter(
    (t) => !held.has(t) && new Date(`${dateStr}T${t}:00`) > now
  );
}

/// Why `startsAt` cannot be booked at this clinic, or null if it can.
///
/// Deliberately does not consider whether the slot is already taken: that is
/// decided by the unique index at INSERT time, because any check here could be
/// overtaken by another patient before the row lands.
function bookingError(clinic, startsAt, now = new Date()) {
  const [dateStr, time] = String(startsAt).split(' ');
  if (!isValidDate(dateStr) || !TIME_RE.test(time ?? '')) {
    return 'startsAt must look like "YYYY-MM-DD HH:MM"';
  }

  const when = new Date(`${dateStr}T${time}:00`);
  if (when <= now) {
    return 'Appointments must be booked in advance';
  }

  const horizon = new Date(now);
  horizon.setDate(horizon.getDate() + MAX_ADVANCE_DAYS);
  if (when > horizon) {
    return `Appointments can be booked at most ${MAX_ADVANCE_DAYS} days ahead`;
  }

  if (!isOpenOn(clinic, dateStr)) {
    return `${clinic.name} is closed that day`;
  }
  if (!slotsForDate(clinic, dateStr).includes(time)) {
    return `${time} is not an appointment slot at ${clinic.name}`;
  }
  return null;
}

/// Why these clinic details are unacceptable, or null if they are fine.
function clinicError(fields) {
  const { name, kind, opens_at, closes_at, slot_minutes, open_days } = fields;

  if (!name || !String(name).trim()) return 'name is required';
  if (!KINDS.includes(kind)) return `kind must be one of: ${KINDS.join(', ')}`;
  if (!TIME_RE.test(opens_at ?? '') || !TIME_RE.test(closes_at ?? '')) {
    return 'opensAt and closesAt must look like "HH:MM"';
  }
  if (minutesOf(closes_at) <= minutesOf(opens_at)) {
    return 'closesAt must be after opensAt';
  }

  const step = Number(slot_minutes);
  if (!Number.isInteger(step) || step < 5 || step > 240) {
    return 'slotMinutes must be a whole number between 5 and 240';
  }
  if (minutesOf(opens_at) + step > minutesOf(closes_at)) {
    return 'The clinic is not open long enough to fit one appointment slot';
  }

  if (openDays({ open_days }).length === 0) {
    return 'openDays must list at least one weekday (1 = Monday … 7 = Sunday)';
  }
  return null;
}

module.exports = {
  HELD_STATUSES,
  STATUSES,
  DOCTOR_DECISIONS,
  ALLOWED_TRANSITIONS,
  KINDS,
  MAX_ADVANCE_DAYS,
  availableSlots,
  bookingError,
  clinicError,
  isValidDate,
  normalizeStartsAt,
  slotsForDate,
  toDateString,
};
