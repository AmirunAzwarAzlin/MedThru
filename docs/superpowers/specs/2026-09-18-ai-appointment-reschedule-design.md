# AI-assisted appointment reschedule — design

**Date:** 2026-09-18
**Status:** Approved for planning
**Area:** Backend (`server.js`, `db.js`), Patient app (`app/lib/screens/patient/`,
`app/lib/screens/appointments/`), Doctor app (`app/lib/screens/doctor/`)

## Goal

Let a patient or a doctor propose moving an existing **confirmed** appointment to
a different time, with the system suggesting good alternative slots instead of
making either side hunt through raw availability. The suggestion ranks candidate
slots by a deterministic score that weighs both sides of the exchange — how well
a slot fits the patient, and how well it fits the doctor's day — then asks the
Gemini API to turn the top few into a short, human-readable rationale.

This builds directly on the appointment system that already exists (`server.js`
§"Clinics and appointments"): request → confirm/reject → cancel, one active slot
per `(clinic_id, starts_at)` enforced by a partial unique index. Reschedule is a
new transition on top of that state machine, not a replacement for it.

## Non-goals

- No change to the initial booking flow's trust model: patients still book with
  just their card, no login.
- No changing which clinic or doctor an appointment belongs to as part of a
  reschedule — only the time changes. Moving to a different doctor is a fresh
  booking.
- The AI does not decide anything; the deterministic scorer produces the ranked
  list, Gemini only narrates the top candidates. A Gemini outage degrades to a
  templated rationale, it never blocks the feature.
- No raw clinical data (reason text, health records) leaves the server. Only a
  coarse, server-computed urgency tag is sent to Gemini.

## Data model changes

```sql
ALTER TABLE doctors      ADD COLUMN clinic_id INTEGER REFERENCES clinics(id);
ALTER TABLE appointments ADD COLUMN doctor_id INTEGER REFERENCES doctors(id);
ALTER TABLE appointments ADD COLUMN proposed_starts_at TEXT;
ALTER TABLE appointments ADD COLUMN proposed_by        TEXT;  -- 'patient' | 'doctor'
ALTER TABLE appointments ADD COLUMN reschedule_reason   TEXT;  -- optional free text
```

Both new foreign keys are nullable. Existing doctor rows (no `clinic_id`) and
existing appointments (no `doctor_id`) keep working — they fall back to
clinic-wide scoring (see "AI suggestion engine" below) rather than per-doctor
scoring, until a doctor is assigned.

**The slot-uniqueness index must be updated in lockstep with the new status.**
`db.js` currently hardcodes the double-booking guard independently of the
`HELD_STATUSES` constant:

```sql
CREATE UNIQUE INDEX IF NOT EXISTS idx_appointments_slot
  ON appointments(clinic_id, starts_at)
  WHERE status IN ('requested', 'confirmed');
```

This must become `WHERE status IN ('requested', 'confirmed', 'reschedule_requested')`
— otherwise a pending reschedule silently drops out of the uniqueness guarantee
and its original slot could be double-booked out from under it. `appointments.js`
also needs updating to match:

```js
const HELD_STATUSES = ['requested', 'confirmed', 'reschedule_requested'];

const ALLOWED_TRANSITIONS = {
  requested: ['confirmed', 'rejected', 'cancelled'],
  confirmed: ['cancelled', 'completed', 'reschedule_requested'],
  reschedule_requested: ['confirmed', 'cancelled'],
};
```

Both the index predicate and these two constants are one fact three times over —
worth a smoke test that asserts they agree, since nothing in the type system
will catch them drifting apart again.

**Booking flow change (required for `doctor_id` to be populated going forward):**
a patient now picks a doctor at the chosen clinic before picking a slot.

- New endpoint `GET /api/clinics/:id/doctors` — active doctors at that clinic.
- `GET /api/clinics/:id/availability` gains an optional `doctorId` query param;
  when present, `heldTimes()` filters by `doctor_id` instead of clinic-wide, so
  two doctors at the same clinic don't block each other's slots.
- `POST .../appointments` (booking) accepts `doctorId`, stored on the new
  appointment. Optional at the API level (stays nullable) so existing tests and
  any client not yet updated don't break, but the patient app's booking screen
  always sends one.

## State machine

New status `reschedule_requested`, added to `HELD_STATUSES` — the original slot
stays held (blocking rebooking) while a reschedule is pending.

```
confirmed --(patient or doctor proposes a new time)--> reschedule_requested
reschedule_requested --(other party accepts)--> confirmed, starts_at = proposed_starts_at
reschedule_requested --(other party rejects)--> confirmed, starts_at unchanged
reschedule_requested --(either party cancels outright)--> cancelled   [existing cancel action]
```

Only a `confirmed` appointment can enter `reschedule_requested`. A still-`requested`
appointment isn't eligible — either party can just cancel/withdraw and rebook.

On accept, the server re-validates the partial unique index on
`(clinic_id, starts_at)` before committing the `UPDATE`. If another appointment
has taken that slot in the meantime, the update fails and the client sees a
409-style conflict — same failure shape as a normal double-booking attempt today.

## API surface

Mirrors the existing patient-token / doctor-auth split used everywhere else in
the appointments API.

| Endpoint | Who | Effect |
|---|---|---|
| `GET /api/patients/token/:token/appointments/:id/reschedule/suggestions` | patient | Ranked candidate slots + AI rationale |
| `GET /api/appointments/:id/reschedule/suggestions` | doctor (`requireDoctor`) | Same, doctor-auth variant |
| `POST /api/patients/token/:token/appointments/:id/reschedule` | patient | `{ startsAt }` → sets `reschedule_requested`, `proposed_by: 'patient'` |
| `POST /api/appointments/:id/reschedule` | doctor | `{ startsAt }` → sets `reschedule_requested`, `proposed_by: 'doctor'` |
| `POST /api/patients/token/:token/appointments/:id/reschedule/respond` | patient | `{ accept: bool }` — only valid when `proposed_by === 'doctor'` |
| `POST /api/appointments/:id/reschedule/respond` | doctor | `{ accept: bool }` — only valid when `proposed_by === 'patient'` |

All routes reuse the existing patient-scoping guarantee (token resolves to a
patient, appointment looked up by `id AND patient_id`) and the existing
`lookupLimiter` / `requireDoctor` middleware already in place for the sibling
endpoints.

On `respond`, whether accepted or rejected, `proposed_starts_at`, `proposed_by`,
and `reschedule_reason` are cleared and status returns to `confirmed`; only
`starts_at` itself changes, and only on accept. Each propose/accept/reject calls
`logAudit()` (the same helper already used by booking, cancel, and decision),
matching the project's "every read and write is audited" invariant.

## AI suggestion engine

**Candidate generation.** For the appointment's `doctor_id` (or clinic-wide if
null), gather open slots over the next 14 days using the existing
`availableSlots()` helper, scoped by the availability change above, excluding
the appointment's current slot.

**Scoring**, computed server-side, no network call:

- `patientFit`: closeness to the original slot's weekday/time-of-day, soonness,
  plus an urgency bonus derived from the appointment's `reason` text and the
  patient's flagged chronic conditions / recent abnormal readings.
- `clinicFit`: whether taking the slot fills a gap in that doctor's day or
  fragments it, and whether it keeps the day's load balanced against the
  clinic's typical density.
- `total = w1*patientFit + w2*clinicFit` — weights are constants, tunable
  without a schema change.

Top 3–5 candidates by `total` go to Gemini with **redacted context only**: a
coarse urgency tag (e.g. `routine` / `elevated` / `urgent`, computed server-side
— not the raw `reason` string, not health record contents) plus each candidate's
day/time and score breakdown. Gemini returns a 1–2 sentence rationale per
candidate. If the call fails or times out, fall back to a templated rationale
("Closest match to your original time" / "Fills an open slot in your doctor's
day") — the ranked list still renders.

**API key handling.** `GEMINI_API_KEY` is read from an environment variable
only — never hardcoded, never committed. Unlike `JWT_SECRET` in `auth.js`
(which falls back to a dev value, a known open gap tracked in the phase 1
proposal), there is no fallback key: a missing key takes the same degraded
path as a failed Gemini call, since a fallback API key isn't a meaningful
concept. `.env` / `.env.*` are already in `.gitignore`; the project doesn't
currently load a `.env` file anywhere, so this adds `dotenv` as a dependency
and a `require('dotenv').config()` call so a local key is actually picked up
in development.

**Connecting to Gemini.** A new single-purpose module, `gemini.js` (alongside
`tokens.js`, `ratelimit.js`, `appointments.js`), exports one function:
`rationalizeCandidates({ originalSlot, urgencyTag, candidates })`.

- **Client**: the official Google GenAI Node SDK, initialized once at startup
  from `GEMINI_API_KEY`. If the key is unset, the function returns `null`
  immediately without attempting a network call — same fallback path as a
  failed call.
- **Model**: `gemini-2.5-flash`. The task is captioning an already-ranked list,
  not open-ended reasoning; a fast/cheap model is the right fit for a call made
  inline in a request handler.
- **Structured output, not free text.** The request sets
  `responseMimeType: "application/json"` with a `responseSchema` forcing the
  shape `{ suggestions: [{ startsAt, rationale }] }`. This avoids parsing
  free-form prose (and the prompt-injection surface that comes with it) — a
  malformed response is just a JSON parse the caller catches and falls back on.
- **Prompt contents**: exactly the redacted context above — original slot
  day/time, the coarse `urgencyTag`, and each candidate's day/time plus its
  `patientFit`/`clinicFit` score breakdown. Nothing else.
- **Timeout**: wrapped in a hard ~4-second timeout. The suggestions endpoint is
  a synchronous GET a user is waiting on; it cannot hang on a third-party call.
  Timeout, non-2xx, or a schema-violating response all fall back to the
  templated rationale, with no retry.
- **No response caching** for the first pass — a repeated-refresh quota concern
  is a cheap follow-up (in-memory cache keyed by appointment id), not a
  day-one requirement.

## Client UI

**Patient** (`app/lib/screens/patient/appointments_screen.dart`): confirmed
appointments get a "Reschedule" action alongside the existing Cancel/Remind/Add
to calendar row. It opens a new screen showing the AI-suggested slots (each with
its rationale) plus a manual time picker reusing the existing availability UI
from `book_appointment_screen.dart`. If the appointment is `reschedule_requested`
with `proposed_by: 'doctor'`, the card shows an Accept/Decline banner instead of
the normal actions.

**Doctor** (`app/lib/screens/doctor/appointment_queue_screen.dart`): a new
`reschedule_requested` filter tab alongside the existing five. Confirmed cards
get a "Propose reschedule" action (same suggestion screen, doctor-auth
endpoints); cards with `proposed_by: 'patient'` show Accept/Decline instead of
Confirm/Reject.

**Booking** (`app/lib/screens/appointments/book_appointment_screen.dart`): add a
doctor-selection step between clinic and slot, populated from the new
`GET /api/clinics/:id/doctors` endpoint.

## Testing

Extend `test/smoke.js`:

- Doctor→clinic linkage and clinic→doctors listing.
- Booking with a `doctorId` scopes availability/held-times per doctor, not
  clinic-wide.
- Propose-as-patient → accept-as-doctor moves `starts_at` and returns to
  `confirmed`.
- Propose-as-patient → reject-as-doctor leaves `starts_at` unchanged.
- Propose-as-doctor → accept/reject-as-patient, symmetric to the above.
- The original slot stays in `HELD_STATUSES` (blocks rebooking) while
  `reschedule_requested`.
- A conflicting accept (slot taken by another appointment in the meantime) is
  rejected without corrupting appointment state.
- An appointment with `doctor_id: null` still returns clinic-wide suggestions
  without erroring.
- Cross-patient scoping: card A cannot propose/respond to card B's appointment.
