# Closing the contraindication bypass gap — design

**Date:** 2026-09-23
**Status:** Approved for planning
**Area:** Backend (`server.js`), Doctor app (`app/lib/api.dart`,
`app/lib/screens/health_records/add_medication_screen.dart`,
`app/lib/screens/health_records/add_vaccination_screen.dart`)

## Background

The triage contraindication engine (`docs/superpowers/specs/2026-09-23-contraindication-engine-design.md`)
shipped `POST /contraindication-check` and `POST /contraindication-override`
as a pre-save advisory step the doctor app calls before creating a
medication or vaccination. The final review of that work found a real gap:
the actual write — `POST /api/patients/token/:token/medications` (and
`vaccinations`), built by the shared `registerHealthRecords` factory — has
no idea the contraindication engine exists. Nothing correlates a save with
a prior check or override. A hard-stopped medication can be saved directly,
with no block and no audit trace that the check was skipped, because the
check was never anything more than a side-channel the app UI happened to
call.

This design closes that gap by moving enforcement into the write path
itself.

## Goal

A doctor-sourced write to a medication or vaccination (create or edit) that
matches a hard-stop rule is rejected server-side unless the request carries
a non-blank override reason, which is then audited. This makes "a hard stop
can never be silently overridden" actually true, not just true of the one
UI path that happens to call the check first.

## Non-goals

- No change to the Gemini judgment layer or its endpoint
  (`/contraindication-check` stays exactly as it is, still doctor-only,
  still advisory, still skipped once a hard stop already fires). Only the
  deterministic hard-stop layer gets enforced at write time — re-running
  Gemini synchronously in the write path would reintroduce a network
  dependency into a save, which the original design explicitly ruled out.
- No enforcement on patient self-reported entries (`source: 'patient'`) —
  unchanged from the original scope.
- No enforcement on any other record type. Only `medications` and
  `vaccinations` opt in.
- No new database table or migration — reuses `contraindication_rules` and
  `contraindication.js`'s `checkHardStops` unchanged.

## Server changes

### `registerHealthRecords` gains an opt-in `contraindicationField`

```js
function registerHealthRecords({ path, table, requiredKeys, columns, orderBy, contraindicationField }) {
```

Only the `medications` and `vaccinations` call sites set it:

```js
registerHealthRecords({
  path: 'medications',
  // ...
  contraindicationField: 'name',
});

registerHealthRecords({
  path: 'vaccinations',
  // ...
  contraindicationField: 'vaccine',
});
```

The other four call sites (`allergies`, `medical-history`,
`emergency-contacts`, `lab-results`) pass nothing and are untouched — the
new logic lives behind `if (contraindicationField) { ... }` inside the
shared POST and PUT handlers, so it costs those four types nothing to read
or reason about.

**Why extend the shared factory instead of writing bespoke routes for
medications/vaccinations:** the alternative duplicates the insert/update/
audit boilerplate `registerHealthRecords` already provides across four new
handlers (POST × 2 types, PUT × 2 types) — real logic duplication, and it
splits each type's routes across two locations in the file (GET/DELETE
from the factory, POST/PUT hand-written). One optional config key, used by
exactly two of six call sites, is a smaller and more maintainable change.

### A new `enforceContraindication` helper, called from POST and PUT

```js
/// Runs the deterministic hard-stop check for a doctor-sourced medication/
/// vaccination write, when the call site opted in via `contraindicationField`.
/// Returns null to let the write through (nothing matched, or a valid
/// override reason was supplied and has already been audited); returns a
/// response body to send with 409 when the write must be rejected.
///
/// `excludeId` is the row's own id on a PUT, so editing a medication's name
/// never sees its own pre-edit value as a colliding "existing medication" —
/// without this, renaming a row would spuriously match itself.
function enforceContraindication({ contraindicationField, req, patient, doctor, excludeId }) {
  if (!contraindicationField || !doctor) return null;

  const proposedName = req.body[contraindicationField];
  if (typeof proposedName !== 'string' || !proposedName.trim()) return null;

  const allergenRows = db.prepare(`SELECT allergen FROM allergies WHERE patient_id = ?`).all(patient.id);
  const rules = db.prepare(`SELECT * FROM contraindication_rules`).all();
  const hardStops = checkHardStops({
    rules,
    allergies: allergenRows,
    medications: activeMedicationNames(patient.id, excludeId ?? null),
    proposedName,
  });

  if (hardStops.length === 0) return null;

  const overrideReason = req.body.overrideReason;
  if (typeof overrideReason === 'string' && overrideReason.trim()) {
    logAudit(patient.id, doctor.id, 'contraindication_override', JSON.stringify({
      proposedName,
      ruleIds: hardStops.map((h) => h.ruleId),
      reason: overrideReason.trim(),
    }));
    return null;
  }

  return { error: 'This treatment may be dangerous for this patient.', hardStops };
}
```

Called in the POST handler right after `doctor` is computed:

```js
const doctor = doctorFromRequest(req);
const blocked = enforceContraindication({ contraindicationField, req, patient, doctor });
if (blocked) return res.status(409).json(blocked);
```

And in the PUT handler, moved to run before the `UPDATE`, with `doctor`
computed earlier than it currently is:

```js
const doctor = doctorFromRequest(req);
const blocked = enforceContraindication({
  contraindicationField, req, patient, doctor, excludeId: existing.id,
});
if (blocked) return res.status(409).json(blocked);
```

### `activeMedicationNames` gains an optional exclusion

```js
function activeMedicationNames(patientId, excludeId = null) {
  return db.prepare(
    `SELECT name FROM medications
     WHERE patient_id = ? AND (end_date IS NULL OR end_date >= date('now'))
       AND (? IS NULL OR id != ?)`
  ).all(patientId, excludeId, excludeId);
}
```

The existing call from `/contraindication-check` passes no second argument,
so its behavior is unchanged.

### `POST /contraindication-override` is deleted

Its job — logging an override with a reason — now happens inline inside
`enforceContraindication`, computed from server-side rule matches rather
than trusting a client-supplied rule id list. `/contraindication-check`
itself is untouched.

## Client changes (`app/lib/api.dart`)

`addMedication`, `updateMedication`, `addVaccination`, `updateVaccination`
each gain an optional `overrideReason` parameter, sent as `overrideReason`
in the body when non-null and non-empty. `overrideContraindication` is
deleted.

A new exception type carries a 409's `hardStops` back to the caller instead
of collapsing into a generic string:

```dart
class ContraindicationBlockedException implements Exception {
  const ContraindicationBlockedException(this.hardStops);
  final List<Map<String, dynamic>> hardStops;
}
```

`_addByToken`/`_updateByToken` (or the four methods directly, whichever
reads cleaner once written) check for status `409` before falling through
to the generic `_errorFrom` path, and throw
`ContraindicationBlockedException(hardStops)` instead.

## Client changes (both add-screens)

`_runContraindicationCheck()` no longer calls an override endpoint — it
returns the typed reason (or `null`/`true`/`false` as before) up to
`_save()`, which passes it straight into the create/update call as
`overrideReason`.

The `!_isEdit` exclusion is removed: editing now runs the identical
check → dialog → save sequence as creating.

The actual save/update call is wrapped to catch
`ContraindicationBlockedException` — this is the race-condition path,
where the pre-check came back clean but the write-time recheck found
something (e.g. another user logged a new allergy in between). On catch,
show the same `showHardStopOverrideDialog` with the exception's
`hardStops`, then retry the save with the collected reason.

## Testing

Extend `test/smoke.js` (no new unit-test file — this reuses
`checkHardStops` unchanged):

- Doctor POSTs a hard-stopped medication with no `overrideReason` → 409,
  body includes `hardStops`.
- Same POST with a valid `overrideReason` → 201; `audit_log` carries both
  the `medications_add` and `contraindication_override` entries.
- Doctor PUTs an existing medication into a hard-stopped name → same
  409/201-with-reason pattern.
- Editing a medication's own name doesn't trigger against its own
  pre-edit value (the `excludeId` exclusion).
- A patient's self-reported save (no doctor bearer token) of the same
  hard-stopped name succeeds unblocked.
- An unrelated medication save produces no extra audit entries beyond the
  normal add/edit one.
- One vaccination case (egg allergy vs. an egg-based flu vaccine) proving
  the `contraindicationField: 'vaccine'` mapping works, not just `'name'`.
- `POST /contraindication-override` returns 404 (route removed); the
  existing smoke block that used it is rewritten to the new flow (check →
  POST/PUT with `overrideReason` → assert audit entries).

Flutter: no widget-test harness exists for these screens (established
project convention). Verify via `flutter analyze`, plus a manual
walkthrough note covering both the create and the now-enforced edit flow.

## Known limitations (accepted)

Two edge cases were raised in review and are accepted as-is rather than fixed:

- **An override reason can cover a hard stop the doctor never saw.** If the pre-check
  shows rule A, the doctor types a reason, and — before the save lands — a new allergy
  is logged that also matches rule B, the write is still accepted and both A and B are
  logged as overridden under the one reason the doctor typed for A. The window is
  narrow (between the pre-check call and the save call) and this is still a strict
  improvement over the pre-existing behavior (no enforcement at all), but it means the
  audit trail can show a rule being "overridden" that was never actually shown to the
  doctor. Closing this fully would require the client to send back the specific rule
  ids it showed the doctor, with the server rejecting if its own computed set isn't a
  subset of those — not implemented, since the gap is narrow and mostly theoretical.
- **Every edit that touches a hard-stopped medication's name re-triggers the check,
  even if the name isn't what changed.** Editing only the dosage of an
  already-overridding Amoxicillin entry re-runs the hard-stop check against the
  (unchanged) name and requires a fresh override reason. This is intentional, not an
  oversight — every write is independently re-audited, which is the same principle
  behind enforcing at write time in the first place — but it does mean a doctor making
  an unrelated small edit to a flagged medication will be asked to re-justify it.
