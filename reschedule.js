/// Deterministic scoring for AI-assisted appointment rescheduling.
///
/// Two independent 0-100 scores per candidate slot: how well it fits the
/// patient (closeness to their original time, urgency) and how well it fits
/// the doctor's day (fills a gap rather than fragmenting it, keeps the day's
/// load near what's typical). The two combine into one ranking; nothing here
/// talks to Gemini or the database — see `gemini.js` and `server.js`.

const URGENCY_KEYWORDS = {
  urgent: ['urgent', 'severe', 'emergency', 'acute'],
  elevated: ['follow-up', 'follow up', 'pain', 'worsening', 'chronic'],
};

/// A coarse, non-clinical urgency tag from free text plus whether the patient
/// has a chronic condition on file. This tag — never the raw reason text —
/// is the only signal that reaches Gemini.
function urgencyTag(reason, hasChronicCondition) {
  const text = String(reason ?? '').toLowerCase();
  if (URGENCY_KEYWORDS.urgent.some((k) => text.includes(k))) return 'urgent';
  if (hasChronicCondition || URGENCY_KEYWORDS.elevated.some((k) => text.includes(k))) {
    return 'elevated';
  }
  return 'routine';
}

const URGENCY_WEIGHT = { routine: 0, elevated: 15, urgent: 30 };

function minutesOfDay(hhmm) {
  const [h, m] = hhmm.split(':').map(Number);
  return h * 60 + m;
}

/// How well `candidateStartsAt` ("YYYY-MM-DD HH:MM") fits the patient, 0-100
/// (higher is better): closer to the original slot's time-of-day, sooner,
/// and bumped for elevated/urgent cases.
function patientFit({ originalStartsAt, candidateStartsAt, tag, now = new Date() }) {
  const [, origTime] = originalStartsAt.split(' ');
  const [candDate, candTime] = candidateStartsAt.split(' ');

  const timeDelta = Math.abs(minutesOfDay(candTime) - minutesOfDay(origTime));
  const timeScore = Math.max(0, 40 - timeDelta / 6); // same time -> 40, 4h+ apart -> 0

  const daysOut = Math.max(0, (new Date(`${candDate}T${candTime}:00`) - now) / 86_400_000);
  const soonScore = Math.max(0, 30 - daysOut * 2); // today -> 30, 15+ days out -> 0

  return Math.min(100, timeScore + soonScore + URGENCY_WEIGHT[tag]);
}

/// How well `candidateStartsAt` fits the doctor's day, 0-100 (higher is
/// better): rewards a slot immediately adjacent to an existing booking that
/// day over one sitting alone, and penalizes a day already above its
/// typical load (0 disables the penalty — used when there isn't enough
/// history for a doctor yet).
function clinicFit({ candidateStartsAt, sameDayBookedTimes, slotMinutes, typicalDailyLoad }) {
  const [, candTime] = candidateStartsAt.split(' ');
  const candMin = minutesOfDay(candTime);

  const gapBonus = sameDayBookedTimes.some(
    (t) => Math.abs(minutesOfDay(t) - candMin) === slotMinutes
  ) ? 40 : 0;

  const projectedLoad = sameDayBookedTimes.length + 1;
  const loadPenalty = typicalDailyLoad > 0
    ? Math.max(0, (projectedLoad - typicalDailyLoad) * 10)
    : 0;

  return Math.max(0, Math.min(100, 60 + gapBonus - loadPenalty));
}

const PATIENT_WEIGHT = 0.6;
const CLINIC_WEIGHT = 0.4;

/// Ranks `candidates` (array of "YYYY-MM-DD HH:MM" strings) best-first,
/// returning at most `limit` with their score breakdown.
function rankCandidates({
  originalStartsAt, candidates, tag, sameDayBookedTimesByDate,
  slotMinutes, typicalDailyLoad, now, limit = 5,
}) {
  const scored = candidates.map((candidateStartsAt) => {
    const [candDate] = candidateStartsAt.split(' ');
    const pFit = patientFit({ originalStartsAt, candidateStartsAt, tag, now });
    const cFit = clinicFit({
      candidateStartsAt,
      sameDayBookedTimes: sameDayBookedTimesByDate[candDate] ?? [],
      slotMinutes,
      typicalDailyLoad,
    });
    return {
      startsAt: candidateStartsAt,
      patientFit: pFit,
      clinicFit: cFit,
      total: PATIENT_WEIGHT * pFit + CLINIC_WEIGHT * cFit,
    };
  });
  scored.sort((a, b) => b.total - a.total);
  return scored.slice(0, limit);
}

module.exports = { urgencyTag, patientFit, clinicFit, rankCandidates };
