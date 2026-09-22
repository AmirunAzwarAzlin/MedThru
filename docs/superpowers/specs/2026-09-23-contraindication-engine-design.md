# Triage contraindication engine — design

**Date:** 2026-09-23
**Status:** Approved for planning
**Area:** Backend (`server.js`, `db.js`, new `contraindication.js` /
`contraindication-gemini.js`), Doctor app (`app/lib/screens/doctor/`)

## Goal

When a doctor is about to add a medication or vaccination to a patient's
record, cross-reference the proposed treatment against that patient's logged
allergies and active medications, and flag a dangerous interaction *before*
it's saved — instead of relying on the doctor to remember or manually cross-
check.

Two layers judge every proposed treatment:

1. **Deterministic hard-stop rules** — a small curated set of well-known,
   high-severity conflicts (classic allergen-class ↔ drug-class reactions,
   classic drug ↔ drug interactions), matched by keyword. Always runs, never
   depends on network access, and can never be silently overridden — a match
   forces the doctor to type a reason before proceeding.
2. **Gemini judgment** — layered on top for broader/fuzzier cases outside the
   curated list. Only consulted when the hard-stop layer found nothing.
   Produces a dismissible warning, not a block: it's a judgment call, not an
   established fact, so it doesn't carry the same forcing function.

This mirrors the reschedule feature's existing split of responsibility
(`reschedule.js` decides deterministically, `gemini.js` only narrates) —
here Gemini decides the *soft* signal, never the hard one.

## Non-goals

- No check on the patient's own self-reported medications/allergies entries
  (source `'patient'`) — this is about a doctor proposing a *new* treatment,
  not retroactively logging existing ones.
- No check on other record types (lab results, procedures, documents). Scope
  is medications and vaccinations only.
- The hard-stop rule list is not exhaustive medical literature — it's a
  starter set of textbook-known conflicts, extensible later through the admin
  screen. It is not a substitute for clinical judgment.
- No raw clinical history beyond the current allergy/medication lists is sent
  to Gemini — no notes, no lab results, no diagnoses.
- A Gemini outage never blocks saving a treatment — only the deterministic
  layer can block.

## Data model changes

New table, seeded in `db.js` the same way `clinics` is seeded (insert only if
empty):

```sql
CREATE TABLE IF NOT EXISTS contraindication_rules (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  rule_type TEXT NOT NULL,            -- 'allergy' | 'medication'
  trigger_terms TEXT NOT NULL,        -- comma-separated keywords, matched
                                       -- against an existing allergen or
                                       -- active medication name
  treatment_terms TEXT NOT NULL,      -- comma-separated keywords, matched
                                       -- against the proposed treatment name
  severity TEXT NOT NULL DEFAULT 'high',
  reason TEXT NOT NULL,               -- shown to the doctor verbatim
  created_by INTEGER REFERENCES doctors(id),
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
```

`rule_type` says what existing patient data the rule watches: an allergy
entry, or an existing active medication. `treatment_terms` is always matched
against the name of whatever's being proposed (medication or vaccine).

**Seed set** (~18 rules, `created_by NULL`), covering:
- Penicillin-class allergy → penicillin/amoxicillin/ampicillin/augmentin
- Sulfa allergy → sulfamethoxazole/bactrim/sulfasalazine
- NSAID/aspirin allergy → ibuprofen/naproxen/aspirin/diclofenac
- Egg allergy → egg-based influenza vaccine, yellow fever vaccine
- Gelatin allergy → MMR vaccine, varicella vaccine
- Existing warfarin → NSAIDs/aspirin (bleeding risk)
- Existing warfarin → ciprofloxacin/metronidazole (INR increase)
- Existing MAOI (phenelzine/tranylcypromine) → SSRIs/pseudoephedrine
  (serotonin syndrome / hypertensive crisis)
- Existing statin (simvastatin/atorvastatin) → clarithromycin/erythromycin
  (rhabdomyolysis risk)
- Existing methotrexate → NSAIDs (toxicity)

Exact list finalized during implementation; each entry needs a real,
defensible clinical reason string, not a placeholder.

## Matching engine — `contraindication.js`

Pure, synchronous, no DB or network access — same shape as `reschedule.js`,
fully unit-testable with hand-built inputs.

```js
checkHardStops({ rules, allergies, medications, proposedName })
```

- `allergies`: `[{ allergen }]` for the patient.
- `medications`: `[{ name }]` for the patient's currently active medications
  (`end_date IS NULL OR end_date >= today`).
- `proposedName`: the treatment name being proposed.
- For each rule, case-insensitively substring-match every `trigger_term`
  against every allergen/medication name (per `rule_type`), and every
  `treatment_terms` entry against `proposedName`. A rule matches if both
  sides have at least one hit.
- Returns every matching rule as
  `{ ruleId, severity, reason, triggerSource: 'allergy'|'medication', triggerLabel, matchedTreatmentTerm }`
  — `triggerLabel` is the actual allergen/medication text that matched, so
  the UI can say *why* (e.g. "Patient's logged penicillin allergy").

## Gemini judgment — `contraindication-gemini.js`

Same invariants as `gemini.js`: degrades to `null` on any failure, timeout,
missing API key, or schema-violating response — never throws, never blocks a
save.

```js
judgeContraindication({ allergies, medications, proposedTreatment }, { genAI, timeoutMs })
```

- `proposedTreatment`: `{ name, type: 'medication'|'vaccination', dosage? }`.
- Only called by the server when `checkHardStops` returned no matches (no
  reason to spend latency/cost on a second opinion once we're already
  blocking).
- Structured output (`responseSchema`), not free text — same rationale as
  the reschedule feature: `{ flagged: boolean, severity: 'low'|'moderate'|'high', reason: string }`.
- Prompt contents: the patient's allergy list (allergen, reaction, severity)
  and active medication list (name, dosage, frequency), plus the proposed
  treatment's name/type/dosage. Nothing else — no notes, no diagnoses.
- Model/timeout: reuse `gemini-flash-lite-latest` and the 10s timeout
  constant already tuned in `gemini.js` (extract to a shared constant if
  convenient, otherwise duplicate — no need to overengineer a shared config
  module for two files).

## API surface

| Endpoint | Who | Effect |
|---|---|---|
| `POST /api/patients/token/:token/contraindication-check` | doctor (`requireDoctor`, `lookupLimiter`) | Body `{ treatmentType, treatmentName, dosage? }`. Runs `checkHardStops`, then `judgeContraindication` if clear. Returns `{ hardStops: [...], aiFlag: {...} \| null }`. Logs an audit entry only if something was flagged. |
| `POST /api/patients/token/:token/contraindication-override` | doctor | Body `{ ruleIds, reason, treatmentName }`. Logs the doctor's typed justification to `audit_log` (`action: 'contraindication_override'`). Called only when proceeding past a hard stop. |
| `GET /api/contraindication-rules` | doctor | List all rules (for the admin screen). |
| `POST /api/contraindication-rules` | doctor + `requireAdmin` | Create a rule. |
| `PUT /api/contraindication-rules/:id` | doctor + `requireAdmin` | Edit a rule. |
| `DELETE /api/contraindication-rules/:id` | doctor + `requireAdmin` | Delete a rule. |

The check/override routes follow the same patient-token + doctor-JWT dual
auth already used by `registerHealthRecords`'s POST handler (doctor
prescribing while holding the patient's card), rather than folding
contraindication logic into that generic factory — keeping it a single-
purpose addition doesn't risk running allergy-vs-treatment matching against
unrelated record types like lab results or documents.

## Doctor-facing UX flow

In `add_medication_screen.dart` and `add_vaccination_screen.dart`, the
existing Save action gains a pre-check step:

1. Call `contraindication-check` with the entered name/dosage.
2. If `hardStops` is non-empty: show a blocking dialog listing each matched
   rule's reason. The doctor must type an override reason to proceed (Cancel
   is always available). On confirm, call `contraindication-override`, then
   proceed to the existing create call.
3. Else if `aiFlag` is present: show a dismissible warning dialog with
   Gemini's reason. One tap ("Proceed anyway") continues straight to the
   existing create call — no typed reason, no override-log call.
4. Else: proceed directly, no dialog — no added friction for the common,
   unflagged case.

## Admin rule management

New `contraindication_rules_screen.dart`, reachable from
`doctor_settings_screen.dart` behind `doctor.isAdmin` (same gating already
used for card reissue/revoke and patient deletion). Lists existing rules with
edit/delete, and a form to add a new one (rule type dropdown, trigger-terms
and treatment-terms text fields with a "comma-separated keywords" hint,
severity dropdown, reason text field).

## Testing

- `test/contraindication.js` — pure `checkHardStops` unit tests (no DB, no
  network), mirroring `test/reschedule-scoring.js`: exact keyword match,
  case-insensitivity, no match when only one side hits, multiple rules
  matching at once, active-vs-expired medication filtering.
- A mocked-Gemini test mirroring `test/gemini.js`'s approach: verifies
  `judgeContraindication` degrades to `null` on timeout/error/bad schema, and
  parses a well-formed response correctly.
- Extend `test/smoke.js`: check endpoint returns a hard stop for a seeded
  rule (e.g. penicillin allergy vs. amoxicillin), returns clear for an
  unrelated medication, override endpoint writes an audit row, admin-only
  rule CRUD rejects a non-admin doctor, cross-patient token scoping (card A's
  token can't be used to check against patient B).
