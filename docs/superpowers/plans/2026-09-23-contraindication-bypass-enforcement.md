# Closing the Contraindication Bypass Gap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make "a hard stop can never be silently overridden" actually true by enforcing the deterministic contraindication check inside the medication/vaccination write path itself, not just as an advisory pre-check side-channel the app UI happens to call.

**Architecture:** `registerHealthRecords` (the shared CRUD factory in `server.js` behind allergies/medications/vaccinations/medical-history/emergency-contacts/lab-results) gains an opt-in `contraindicationField` config key, used only by `medications` and `vaccinations`. When set, its POST and PUT handlers re-run the existing pure `checkHardStops` matcher against the submitted name before writing, for doctor-sourced requests only, rejecting with 409 unless an `overrideReason` is supplied. The standalone `POST /contraindication-override` endpoint is deleted — its job now happens inline, computed from server-side matches rather than trusted client input.

**Tech Stack:** Node.js (`node:sqlite`, Express 5), Flutter/Dart.

## Global Constraints

- Only the deterministic hard-stop layer is enforced at write time. The Gemini judgment layer and `/contraindication-check` are untouched — no synchronous Gemini call is added to the write path (would reintroduce a network dependency into a save).
- Enforcement applies only when the request is doctor-sourced (`doctorFromRequest(req)` truthy). A patient's own self-reported save is never blocked.
- Enforcement applies only to `medications` and `vaccinations`. The other four `registerHealthRecords` call sites are untouched.
- Editing a medication's own name must never see its own pre-edit value as a colliding "existing medication" (self-exclusion via `excludeId`).
- No new database table or migration. Reuses `contraindication_rules` and `contraindication.js`'s `checkHardStops` unchanged.

Full design: `docs/superpowers/specs/2026-09-23-contraindication-bypass-enforcement-design.md`.

---

### Task 1: Server-side enforcement on create (POST), endpoint removal

**Files:**
- Modify: `server.js:764` (`registerHealthRecords` signature), `server.js:768-798` (POST handler), `server.js:960-965` (`activeMedicationNames`), `server.js:876-889` and `server.js:891-903` (medications/vaccinations configs), `server.js:1019-1040` (delete `/contraindication-override`)
- Test: `test/smoke.js` (extend/rewrite around `test/smoke.js:594-610`)

**Interfaces:**
- Produces: `enforceContraindication({ contraindicationField, req, patient, doctor, excludeId }) -> { error, hardStops } | null` — a new function in `server.js`, used by both the POST handler (this task) and the PUT handler (Task 2, which passes `excludeId`).
- Produces: `activeMedicationNames(patientId, excludeId = null)` — extends the existing function with a second, optional parameter. The existing call from `/contraindication-check` (unchanged) passes only `patientId`, so its behavior is identical to before.
- Consumes: `checkHardStops` from `contraindication.js` (unchanged, already imported).

- [ ] **Step 1: Write the failing smoke test assertions**

In `test/smoke.js`, find this block (currently at line 594):

```js
    res = await fetch(`${BASE}/patients/token/${cardToken}/contraindication-override`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({
        ruleIds: amoxCheck.hardStops.map((h) => h.ruleId),
        reason: 'Desensitization protocol already in place; proceeding under supervision.',
        treatmentName: 'Amoxicillin',
      }),
    });
    assert(res.status === 201, 'a doctor can log an override for a hard-stopped treatment');

    res = await fetch(`${BASE}/patients/${patient.id}/audit`, { headers: { Authorization: `Bearer ${token}` } });
    const auditEntries = await res.json();
    assert(auditEntries.some((a) => a.action === 'contraindication_override'),
      'the override is written to the audit log');
    assert(auditEntries.some((a) => a.action === 'contraindication_flagged'),
      'the flagged check itself is also written to the audit log');
```

Replace it with:

```js
    // The write path itself now enforces the hard stop, not just the
    // advisory /contraindication-check endpoint. Saving the same
    // hard-stopped medication with no override reason is rejected...
    res = await fetch(`${BASE}/patients/token/${cardToken}/medications`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ name: 'Amoxicillin' }),
    });
    assert(res.status === 409, 'saving a hard-stopped medication without a reason is rejected');
    const blockedSave = await res.json();
    assert(blockedSave.hardStops.length > 0, 'the 409 response carries the matched hard stops');

    // ...but succeeds, and is audited, once a reason is supplied.
    res = await fetch(`${BASE}/patients/token/${cardToken}/medications`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({
        name: 'Amoxicillin',
        overrideReason: 'Desensitization protocol already in place; proceeding under supervision.',
      }),
    });
    assert(res.status === 201, 'the same save succeeds once an override reason is supplied');

    res = await fetch(`${BASE}/patients/${patient.id}/audit`, { headers: { Authorization: `Bearer ${token}` } });
    const auditAfterSave = await res.json();
    assert(auditAfterSave.some((a) => a.action === 'contraindication_override'),
      'the override is written to the audit log by the save itself');
    assert(auditAfterSave.some((a) => a.action === 'medications_add'),
      'the normal add-entry audit line is still written alongside it');
    assert(auditAfterSave.some((a) => a.action === 'contraindication_flagged'),
      'the earlier /contraindication-check call is also on the audit trail');

    // A patient's own self-reported save (no doctor bearer token) is never
    // blocked, regardless of what it matches.
    res = await fetch(`${BASE}/patients/token/${cardToken}/medications`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: 'Amoxicillin' }),
    });
    assert(res.status === 201, "a patient's own self-reported save is never blocked");

    // An unrelated save writes no contraindication audit entry.
    res = await fetch(`${BASE}/patients/${patient.id}/audit`, { headers: { Authorization: `Bearer ${token}` } });
    const overridesBeforeUnrelated =
      (await res.json()).filter((a) => a.action === 'contraindication_override').length;

    res = await fetch(`${BASE}/patients/token/${cardToken}/medications`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ name: 'Paracetamol' }),
    });
    assert(res.status === 201, 'an unrelated medication saves normally');

    res = await fetch(`${BASE}/patients/${patient.id}/audit`, { headers: { Authorization: `Bearer ${token}` } });
    const overridesAfterUnrelated =
      (await res.json()).filter((a) => a.action === 'contraindication_override').length;
    assert(overridesAfterUnrelated === overridesBeforeUnrelated,
      'an unrelated save writes no contraindication audit entry');

    // The check applies to vaccinations too, via a different body field
    // (`vaccine`, not `name`).
    res = await fetch(`${BASE}/patients/token/${cardToken}/allergies`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ allergen: 'Egg' }),
    });
    assert(res.status === 201, 'add an egg allergy for the vaccination hard-stop test');

    res = await fetch(`${BASE}/patients/token/${cardToken}/vaccinations`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ vaccine: 'Influenza vaccine', administeredAt: '2026-01-01' }),
    });
    assert(res.status === 409, 'an egg-based flu vaccine is blocked for a patient with a logged egg allergy');

    res = await fetch(`${BASE}/patients/token/${cardToken}/vaccinations`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({
        vaccine: 'Influenza vaccine',
        administeredAt: '2026-01-01',
        overrideReason: 'Egg-free formulation used, confirmed with pharmacy.',
      }),
    });
    assert(res.status === 201, 'the vaccination saves once an override reason is supplied');

    // The standalone override endpoint is gone — enforcement now lives in
    // the write path itself.
    res = await fetch(`${BASE}/patients/token/${cardToken}/contraindication-override`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ ruleIds: [], reason: 'x', treatmentName: 'x' }),
    });
    assert(res.status === 404, 'the standalone override endpoint has been removed');
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm test`
Expected: FAIL — the new `409` assertions fail because the current POST handler always returns `201` regardless of hard stops, and the `404` assertion for the removed endpoint fails because that route still exists and currently returns `201`.

- [ ] **Step 3: Extend `activeMedicationNames` with an optional exclusion**

In `server.js`, replace:

```js
function activeMedicationNames(patientId) {
  return db.prepare(
    `SELECT name FROM medications
     WHERE patient_id = ? AND (end_date IS NULL OR end_date >= date('now'))`
  ).all(patientId);
}
```

with:

```js
function activeMedicationNames(patientId, excludeId = null) {
  return db.prepare(
    `SELECT name FROM medications
     WHERE patient_id = ? AND (end_date IS NULL OR end_date >= date('now'))
       AND (? IS NULL OR id != ?)`
  ).all(patientId, excludeId, excludeId);
}
```

The one existing call site, inside `/contraindication-check`, passes only
`patient.id` — leave it as-is; its behavior is unchanged.

- [ ] **Step 4: Add the `enforceContraindication` helper**

In `server.js`, right after `activeMedicationsDetailed` (just before
`app.post('/api/patients/token/:token/contraindication-check', ...)`), add:

```js
/// Runs the deterministic hard-stop check for a doctor-sourced medication/
/// vaccination write, when the call site opted in via `contraindicationField`.
/// Returns null to let the write through (nothing matched, or a valid
/// override reason was supplied and has already been audited); returns a
/// response body to send with 409 when the write must be rejected.
///
/// `excludeId` is the row's own id on a PUT, so editing a medication's name
/// never sees its own pre-edit value as a colliding "existing medication" —
/// without this, renaming a row would spuriously match itself. Undefined on
/// a POST, where there is no existing row to exclude.
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

- [ ] **Step 5: Wire it into `registerHealthRecords`'s POST handler**

Change the function signature:

```js
function registerHealthRecords({ path, table, requiredKeys, columns, orderBy, contraindicationField }) {
```

In the POST handler, right after the existing `const doctor = doctorFromRequest(req);` line (before `const dbColumns = ...`), add:

```js
    const blocked = enforceContraindication({ contraindicationField, req, patient, doctor });
    if (blocked) return res.status(409).json(blocked);
```

So the full POST handler reads:

```js
  app.post(`/api/patients/token/:token/${path}`, lookupLimiter, (req, res) => {
    const patient = resolvePatientFromReq(req);
    if (!patient) {
      return res.status(404).json({ error: 'No patient found for this card' });
    }

    for (const key of requiredKeys) {
      const v = req.body[key];
      if (v === undefined || v === null || (typeof v === 'string' && !v.trim())) {
        return res.status(400).json({ error: `${key} is required` });
      }
    }

    const doctor = doctorFromRequest(req);
    const blocked = enforceContraindication({ contraindicationField, req, patient, doctor });
    if (blocked) return res.status(409).json(blocked);

    const dbColumns = ['patient_id', ...columns.map((c) => c.db), 'doctor_id', 'source'];
    const values = [
      patient.id,
      ...columns.map((c) => bodyValue(req, c)),
      doctor ? doctor.id : null,
      doctor ? 'doctor' : 'patient',
    ];
    const placeholders = dbColumns.map(() => '?').join(', ');
    const result = db.prepare(
      `INSERT INTO ${table} (${dbColumns.join(', ')}) VALUES (${placeholders})`
    ).run(...values);

    logAudit(patient.id, doctor ? doctor.id : null, `${table}_add`, `Added a ${path} entry`);
    const row = db.prepare(`${rowSelect} WHERE ${table}.id = ?`)
      .get(Number(result.lastInsertRowid));
    res.status(201).json(row);
  });
```

(The GET, PUT, and DELETE handlers inside `registerHealthRecords` are
untouched by this task — PUT enforcement is Task 2.)

- [ ] **Step 6: Opt in the two call sites**

In the `medications` `registerHealthRecords` call, add `contraindicationField: 'name'`:

```js
registerHealthRecords({
  path: 'medications',
  table: 'medications',
  requiredKeys: ['name'],
  contraindicationField: 'name',
  columns: [
    { body: 'name', db: 'name' },
    { body: 'dosage', db: 'dosage' },
    { body: 'frequency', db: 'frequency' },
    { body: 'startDate', db: 'start_date' },
    { body: 'endDate', db: 'end_date' },
    { body: 'note', db: 'note' },
  ],
  orderBy: 'created_at DESC',
});
```

In the `vaccinations` `registerHealthRecords` call, add `contraindicationField: 'vaccine'`:

```js
registerHealthRecords({
  path: 'vaccinations',
  table: 'vaccinations',
  requiredKeys: ['vaccine', 'administeredAt'],
  contraindicationField: 'vaccine',
  columns: [
    { body: 'vaccine', db: 'vaccine' },
    { body: 'doseNumber', db: 'dose_number' },
    { body: 'administeredAt', db: 'administered_at' },
    { body: 'nextDue', db: 'next_due' },
    { body: 'note', db: 'note' },
  ],
  orderBy: 'administered_at DESC',
});
```

The other four `registerHealthRecords` calls (`allergies`, `medical-history`,
`emergency-contacts`, `lab-results`) are untouched — they simply never pass
`contraindicationField`, so `enforceContraindication` returns `null`
immediately for them.

- [ ] **Step 7: Delete the standalone override endpoint**

In `server.js`, delete this entire route (currently right after the
`/contraindication-check` route, before `app.get('/api/contraindication-rules', ...)`):

```js
app.post('/api/patients/token/:token/contraindication-override', lookupLimiter, requireDoctor, (req, res) => {
  const patient = resolvePatientFromReq(req);
  if (!patient) {
    return res.status(404).json({ error: 'No patient found for this card' });
  }

  const { ruleIds, reason, treatmentName } = req.body;
  if (typeof reason !== 'string' || !reason.trim()) {
    return res.status(400).json({ error: 'reason is required' });
  }
  if (typeof treatmentName !== 'string' || !treatmentName.trim()) {
    return res.status(400).json({ error: 'treatmentName is required' });
  }

  logAudit(patient.id, req.doctor.id, 'contraindication_override', JSON.stringify({
    treatmentName,
    ruleIds: Array.isArray(ruleIds) ? ruleIds : [],
    reason: reason.trim(),
  }));

  res.status(201).json({ logged: true });
});
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `npm test`
Expected: all checks pass, ending with `All smoke checks passed.`

- [ ] **Step 9: Commit**

```bash
git add server.js test/smoke.js
git commit -m "Enforce the contraindication hard stop on medication/vaccination create"
```

---

### Task 2: Server-side enforcement on edit (PUT), self-exclusion

**Files:**
- Modify: `server.js:816-841` (PUT handler inside `registerHealthRecords`)
- Test: `test/smoke.js` (extend, after Task 1's new block)

**Interfaces:**
- Consumes: `enforceContraindication` (Task 1), `contraindicationField` (Task 1, already threaded through the function signature).

- [ ] **Step 1: Write the failing smoke test assertions**

In `test/smoke.js`, right after the block Task 1 added (after the
"the standalone override endpoint has been removed" assertion), add:

```js
    // Editing an existing medication into a hard-stopped name is enforced
    // the same way as creating one.
    res = await fetch(`${BASE}/patients/token/${cardToken}/medications`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ name: 'Metformin' }),
    });
    const editTarget = await res.json();

    res = await fetch(`${BASE}/patients/token/${cardToken}/medications/${editTarget.id}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ name: 'Amoxicillin' }),
    });
    assert(res.status === 409, 'editing a medication into a hard-stopped name is rejected without a reason');

    res = await fetch(`${BASE}/patients/token/${cardToken}/medications/${editTarget.id}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({
        name: 'Amoxicillin',
        overrideReason: 'Same desensitization protocol.',
      }),
    });
    assert(res.status === 200, 'the edit succeeds once an override reason is supplied');

    // Editing a medication's own name never sees its own pre-edit value as
    // a colliding "existing medication" — renaming Warfarin to Ibuprofen
    // must not trip the warfarin/NSAID hard stop against itself.
    res = await fetch(`${BASE}/patients/token/${cardToken}/medications`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ name: 'Warfarin' }),
    });
    const selfEditTarget = await res.json();

    res = await fetch(`${BASE}/patients/token/${cardToken}/medications/${selfEditTarget.id}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ name: 'Ibuprofen' }),
    });
    assert(res.status === 200,
      "renaming a medication does not trigger a hard stop against its own pre-edit value");
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm test`
Expected: FAIL — both `409`/`200` assertions for the edit-blocking cases fail because the PUT handler currently has no enforcement at all (always returns `200`), so the first new assertion (`editing a medication into a hard-stopped name is rejected without a reason`, expecting `409`) fails.

- [ ] **Step 3: Wire enforcement into the PUT handler**

In `server.js`, inside `registerHealthRecords`, replace the PUT handler:

```js
  /// Correct an entry. Scoped to the cardholder: presenting one card never
  /// edits another patient's entry, even with a valid entry id.
  app.put(`/api/patients/token/:token/${path}/:id`, lookupLimiter, (req, res) => {
    const patient = resolvePatientFromReq(req);
    if (!patient) {
      return res.status(404).json({ error: 'No patient found for this card' });
    }
    const existing = db.prepare(`SELECT * FROM ${table} WHERE id = ? AND patient_id = ?`)
      .get(req.params.id, patient.id);
    if (!existing) {
      return res.status(404).json({ error: 'Entry not found' });
    }

    for (const key of requiredKeys) {
      const v = req.body[key];
      if (v === undefined || v === null || (typeof v === 'string' && !v.trim())) {
        return res.status(400).json({ error: `${key} is required` });
      }
    }

    const setClause = columns.map((c) => `${c.db} = ?`).join(', ');
    const values = columns.map((c) => bodyValue(req, c));
    db.prepare(`UPDATE ${table} SET ${setClause} WHERE id = ?`).run(...values, existing.id);

    const doctor = doctorFromRequest(req);
    logAudit(patient.id, doctor ? doctor.id : null, `${table}_edit`, `Edited a ${path} entry`);
    res.json(db.prepare(`${rowSelect} WHERE ${table}.id = ?`).get(existing.id));
  });
```

with:

```js
  /// Correct an entry. Scoped to the cardholder: presenting one card never
  /// edits another patient's entry, even with a valid entry id.
  app.put(`/api/patients/token/:token/${path}/:id`, lookupLimiter, (req, res) => {
    const patient = resolvePatientFromReq(req);
    if (!patient) {
      return res.status(404).json({ error: 'No patient found for this card' });
    }
    const existing = db.prepare(`SELECT * FROM ${table} WHERE id = ? AND patient_id = ?`)
      .get(req.params.id, patient.id);
    if (!existing) {
      return res.status(404).json({ error: 'Entry not found' });
    }

    for (const key of requiredKeys) {
      const v = req.body[key];
      if (v === undefined || v === null || (typeof v === 'string' && !v.trim())) {
        return res.status(400).json({ error: `${key} is required` });
      }
    }

    const doctor = doctorFromRequest(req);
    const blocked = enforceContraindication({
      contraindicationField, req, patient, doctor, excludeId: existing.id,
    });
    if (blocked) return res.status(409).json(blocked);

    const setClause = columns.map((c) => `${c.db} = ?`).join(', ');
    const values = columns.map((c) => bodyValue(req, c));
    db.prepare(`UPDATE ${table} SET ${setClause} WHERE id = ?`).run(...values, existing.id);

    logAudit(patient.id, doctor ? doctor.id : null, `${table}_edit`, `Edited a ${path} entry`);
    res.json(db.prepare(`${rowSelect} WHERE ${table}.id = ?`).get(existing.id));
  });
```

(`doctor` is now computed once, earlier, and reused for both the
enforcement check and the audit log call — the duplicate computation that
used to sit right before `logAudit` is gone.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `npm test`
Expected: all checks pass, ending with `All smoke checks passed.`

- [ ] **Step 5: Commit**

```bash
git add server.js test/smoke.js
git commit -m "Enforce the contraindication hard stop on medication/vaccination edit"
```

---

### Task 3: Flutter API client — `ContraindicationBlockedException` and `overrideReason`

**Files:**
- Modify: `app/lib/api.dart:9-11` (add exception class), `app/lib/api.dart:476-500` (`_addByToken`/`_updateByToken`), `app/lib/api.dart:555-631` (`addMedication`/`updateMedication`/`addVaccination`/`updateVaccination`), `app/lib/api.dart:663-681` (delete `overrideContraindication`)

**Interfaces:**
- Produces: `class ContraindicationBlockedException implements Exception { final List<Map<String, dynamic>> hardStops; }`, thrown by `_addByToken`/`_updateByToken` (and therefore by every method built on them, but in practice only reachable from `addMedication`/`updateMedication`/`addVaccination`/`updateVaccination`, since only those two endpoints ever return a 409 shaped this way).
- Produces: `addMedication`/`updateMedication`/`addVaccination`/`updateVaccination` each gain an optional `String? overrideReason` parameter, sent as `overrideReason` in the request body when non-null and non-empty.
- Consumes: the 409 response shape from Task 1/2 — `{ error, hardStops }`.

- [ ] **Step 1: Add the exception class**

In `app/lib/api.dart`, right after the existing `PasswordRequiredException` class (around line 9-11), add:

```dart
/// Thrown when a medication/vaccination save or edit is rejected because it
/// matches a hard-stop contraindication rule and no override reason was
/// supplied. Carries the matched rules so the caller can show the same
/// override dialog reactively — this is the race-condition path, where the
/// pre-save check came back clean but something changed before the actual
/// write (e.g. a new allergy was logged in between).
class ContraindicationBlockedException implements Exception {
  const ContraindicationBlockedException(this.hardStops);
  final List<Map<String, dynamic>> hardStops;
}
```

- [ ] **Step 2: Make `_addByToken`/`_updateByToken` throw it on a 409**

Replace:

```dart
  Future<Map<String, dynamic>> _addByToken(
      String path, String token, Map<String, dynamic> fields) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/patients/token/$token/$path'),
      headers: _headersFor(token),
      body: jsonEncode(fields),
    );
    if (res.statusCode != 201) {
      throw _errorFrom(res, 'Could not save entry');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _updateByToken(
      String path, String token, int id, Map<String, dynamic> fields) async {
    final res = await http.put(
      Uri.parse('$_baseUrl/patients/token/$token/$path/$id'),
      headers: _headersFor(token),
      body: jsonEncode(fields),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not update entry');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
```

with:

```dart
  Future<Map<String, dynamic>> _addByToken(
      String path, String token, Map<String, dynamic> fields) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/patients/token/$token/$path'),
      headers: _headersFor(token),
      body: jsonEncode(fields),
    );
    if (res.statusCode == 409) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['hardStops'] is List) {
        throw ContraindicationBlockedException(
          (body['hardStops'] as List<dynamic>).cast<Map<String, dynamic>>(),
        );
      }
      throw _errorFrom(res, 'Could not save entry');
    }
    if (res.statusCode != 201) {
      throw _errorFrom(res, 'Could not save entry');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _updateByToken(
      String path, String token, int id, Map<String, dynamic> fields) async {
    final res = await http.put(
      Uri.parse('$_baseUrl/patients/token/$token/$path/$id'),
      headers: _headersFor(token),
      body: jsonEncode(fields),
    );
    if (res.statusCode == 409) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['hardStops'] is List) {
        throw ContraindicationBlockedException(
          (body['hardStops'] as List<dynamic>).cast<Map<String, dynamic>>(),
        );
      }
      throw _errorFrom(res, 'Could not update entry');
    }
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not update entry');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
```

This is shared by all six `registerHealthRecords`-backed record types, but
only medications/vaccinations can ever actually produce a 409 with a
`hardStops` list — the `body['hardStops'] is List` check is what makes this
safe to leave in the shared helper rather than duplicating it.

- [ ] **Step 3: Add `overrideReason` to the four methods**

Replace `addMedication`/`updateMedication`:

```dart
  Future<Map<String, dynamic>> addMedication(
    String token, {
    required String name,
    String? dosage,
    String? frequency,
    String? startDate,
    String? endDate,
    String? note,
  }) =>
      _addByToken('medications', token, {
        'name': name,
        if (dosage != null && dosage.isNotEmpty) 'dosage': dosage,
        if (frequency != null && frequency.isNotEmpty) 'frequency': frequency,
        if (startDate != null && startDate.isNotEmpty) 'startDate': startDate,
        if (endDate != null && endDate.isNotEmpty) 'endDate': endDate,
        if (note != null && note.isNotEmpty) 'note': note,
      });

  Future<Map<String, dynamic>> updateMedication(
    String token,
    int id, {
    required String name,
    String? dosage,
    String? frequency,
    String? startDate,
    String? endDate,
    String? note,
  }) =>
      _updateByToken('medications', token, id, {
        'name': name,
        if (dosage != null && dosage.isNotEmpty) 'dosage': dosage,
        if (frequency != null && frequency.isNotEmpty) 'frequency': frequency,
        if (startDate != null && startDate.isNotEmpty) 'startDate': startDate,
        if (endDate != null && endDate.isNotEmpty) 'endDate': endDate,
        if (note != null && note.isNotEmpty) 'note': note,
      });
```

with:

```dart
  Future<Map<String, dynamic>> addMedication(
    String token, {
    required String name,
    String? dosage,
    String? frequency,
    String? startDate,
    String? endDate,
    String? note,
    String? overrideReason,
  }) =>
      _addByToken('medications', token, {
        'name': name,
        if (dosage != null && dosage.isNotEmpty) 'dosage': dosage,
        if (frequency != null && frequency.isNotEmpty) 'frequency': frequency,
        if (startDate != null && startDate.isNotEmpty) 'startDate': startDate,
        if (endDate != null && endDate.isNotEmpty) 'endDate': endDate,
        if (note != null && note.isNotEmpty) 'note': note,
        if (overrideReason != null && overrideReason.isNotEmpty) 'overrideReason': overrideReason,
      });

  Future<Map<String, dynamic>> updateMedication(
    String token,
    int id, {
    required String name,
    String? dosage,
    String? frequency,
    String? startDate,
    String? endDate,
    String? note,
    String? overrideReason,
  }) =>
      _updateByToken('medications', token, id, {
        'name': name,
        if (dosage != null && dosage.isNotEmpty) 'dosage': dosage,
        if (frequency != null && frequency.isNotEmpty) 'frequency': frequency,
        if (startDate != null && startDate.isNotEmpty) 'startDate': startDate,
        if (endDate != null && endDate.isNotEmpty) 'endDate': endDate,
        if (note != null && note.isNotEmpty) 'note': note,
        if (overrideReason != null && overrideReason.isNotEmpty) 'overrideReason': overrideReason,
      });
```

Replace `addVaccination`/`updateVaccination`:

```dart
  Future<Map<String, dynamic>> addVaccination(
    String token, {
    required String vaccine,
    required String administeredAt,
    int? doseNumber,
    String? nextDue,
    String? note,
  }) =>
      _addByToken('vaccinations', token, {
        'vaccine': vaccine,
        'administeredAt': administeredAt,
        if (doseNumber != null) 'doseNumber': doseNumber,
        if (nextDue != null && nextDue.isNotEmpty) 'nextDue': nextDue,
        if (note != null && note.isNotEmpty) 'note': note,
      });

  Future<Map<String, dynamic>> updateVaccination(
    String token,
    int id, {
    required String vaccine,
    required String administeredAt,
    int? doseNumber,
    String? nextDue,
    String? note,
  }) =>
      _updateByToken('vaccinations', token, id, {
        'vaccine': vaccine,
        'administeredAt': administeredAt,
        if (doseNumber != null) 'doseNumber': doseNumber,
        if (nextDue != null && nextDue.isNotEmpty) 'nextDue': nextDue,
        if (note != null && note.isNotEmpty) 'note': note,
      });
```

with:

```dart
  Future<Map<String, dynamic>> addVaccination(
    String token, {
    required String vaccine,
    required String administeredAt,
    int? doseNumber,
    String? nextDue,
    String? note,
    String? overrideReason,
  }) =>
      _addByToken('vaccinations', token, {
        'vaccine': vaccine,
        'administeredAt': administeredAt,
        if (doseNumber != null) 'doseNumber': doseNumber,
        if (nextDue != null && nextDue.isNotEmpty) 'nextDue': nextDue,
        if (note != null && note.isNotEmpty) 'note': note,
        if (overrideReason != null && overrideReason.isNotEmpty) 'overrideReason': overrideReason,
      });

  Future<Map<String, dynamic>> updateVaccination(
    String token,
    int id, {
    required String vaccine,
    required String administeredAt,
    int? doseNumber,
    String? nextDue,
    String? note,
    String? overrideReason,
  }) =>
      _updateByToken('vaccinations', token, id, {
        'vaccine': vaccine,
        'administeredAt': administeredAt,
        if (doseNumber != null) 'doseNumber': doseNumber,
        if (nextDue != null && nextDue.isNotEmpty) 'nextDue': nextDue,
        if (note != null && note.isNotEmpty) 'note': note,
        if (overrideReason != null && overrideReason.isNotEmpty) 'overrideReason': overrideReason,
      });
```

- [ ] **Step 4: Delete `overrideContraindication`**

In `app/lib/api.dart`, delete this entire method:

```dart
  Future<void> overrideContraindication(
    String token, {
    required List<int> ruleIds,
    required String reason,
    required String treatmentName,
  }) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/patients/token/$token/contraindication-override'),
      headers: _headers,
      body: jsonEncode({
        'ruleIds': ruleIds,
        'reason': reason,
        'treatmentName': treatmentName,
      }),
    );
    if (res.statusCode != 201) {
      throw _errorFrom(res, 'Could not record the override');
    }
  }
```

- [ ] **Step 5: Verify it compiles**

Run: `cd app && flutter analyze lib/api.dart`
Expected: no errors. (`overrideContraindication`'s only two callers are in
the two add-screens, which Task 4 updates — until Task 4 lands, `flutter
analyze` on the whole project would show unresolved-reference errors in
those two screen files. Scoping this run to `lib/api.dart` alone avoids
that false signal for this task.)

- [ ] **Step 6: Commit**

```bash
git add app/lib/api.dart
git commit -m "Add ContraindicationBlockedException and overrideReason to the medication/vaccination API client"
```

---

### Task 4: Wire the enforced save/edit flow into both screens

**Files:**
- Modify: `app/lib/screens/health_records/add_medication_screen.dart`
- Modify: `app/lib/screens/health_records/add_vaccination_screen.dart`

**Interfaces:**
- Consumes: `ContraindicationBlockedException`, the `overrideReason` parameter on `addMedication`/`updateMedication`/`addVaccination`/`updateVaccination` (Task 3); `showHardStopOverrideDialog`/`showAiWarningDialog` from `app/lib/contraindication_dialogs.dart` (unchanged, already imported).

- [ ] **Step 1: Rewrite `add_medication_screen.dart`'s check/save logic**

Replace the existing `_runContraindicationCheck` and `_save` methods:

```dart
  /// Doctor-only pre-check: cross-references this medication against the
  /// patient's logged allergies and active medications before it's saved.
  /// Returns false if the doctor cancels out of a warning; true otherwise
  /// (including when nothing was flagged at all).
  Future<bool> _runContraindicationCheck() async {
    final result = await MedThruApi.instance.checkContraindication(
      widget.token,
      treatmentType: 'medication',
      treatmentName: _name.text.trim(),
      dosage: _dosage.text.trim(),
    );
    final hardStops = (result['hardStops'] as List<dynamic>).cast<Map<String, dynamic>>();
    if (hardStops.isNotEmpty) {
      if (!mounted) return false;
      final reason = await showHardStopOverrideDialog(context, hardStops: hardStops);
      if (reason == null || !mounted) return false;
      await MedThruApi.instance.overrideContraindication(
        widget.token,
        ruleIds: hardStops.map((h) => h['ruleId'] as int).toList(),
        reason: reason,
        treatmentName: _name.text.trim(),
      );
      return true;
    }
    final aiFlag = result['aiFlag'] as Map<String, dynamic>?;
    if (aiFlag != null) {
      if (!mounted) return false;
      return showAiWarningDialog(context, aiFlag: aiFlag);
    }
    return true;
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Enter the medication name.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (!_isEdit && MedThruApi.instance.isLoggedIn) {
        if (mounted) setState(() => _checkingInteractions = true);
        bool proceed;
        try {
          proceed = await _runContraindicationCheck();
        } finally {
          if (mounted) setState(() => _checkingInteractions = false);
        }
        if (!proceed) {
          if (mounted) setState(() => _saving = false);
          return;
        }
      }
      final entry = _isEdit
          ? await MedThruApi.instance.updateMedication(
              widget.token,
              widget.existing!['id'] as int,
              name: _name.text.trim(),
              dosage: _dosage.text.trim(),
              frequency: _frequency.text.trim(),
              startDate: _startDate != null ? _fmt(_startDate!) : null,
              endDate: _endDate != null ? _fmt(_endDate!) : null,
              note: _note.text.trim(),
            )
          : await MedThruApi.instance.addMedication(
              widget.token,
              name: _name.text.trim(),
              dosage: _dosage.text.trim(),
              frequency: _frequency.text.trim(),
              startDate: _startDate != null ? _fmt(_startDate!) : null,
              endDate: _endDate != null ? _fmt(_endDate!) : null,
              note: _note.text.trim(),
            );
      await _applyReminder(entry['id'] as int);
      if (!mounted) return;
      Navigator.pop(context, entry);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
```

with:

```dart
  /// Doctor-only pre-check: cross-references this medication against the
  /// patient's logged allergies and active medications before it's saved.
  /// `(proceed: false, ...)` means the doctor cancelled out of a warning.
  /// `overrideReason` is set when a hard stop was accepted with a typed
  /// reason — passed straight into the save/update call, which is what
  /// actually enforces and audits the override now, not this pre-check.
  Future<({bool proceed, String? overrideReason})> _runContraindicationCheck() async {
    final result = await MedThruApi.instance.checkContraindication(
      widget.token,
      treatmentType: 'medication',
      treatmentName: _name.text.trim(),
      dosage: _dosage.text.trim(),
    );
    final hardStops = (result['hardStops'] as List<dynamic>).cast<Map<String, dynamic>>();
    if (hardStops.isNotEmpty) {
      if (!mounted) return (proceed: false, overrideReason: null);
      final reason = await showHardStopOverrideDialog(context, hardStops: hardStops);
      if (reason == null || !mounted) return (proceed: false, overrideReason: null);
      return (proceed: true, overrideReason: reason);
    }
    final aiFlag = result['aiFlag'] as Map<String, dynamic>?;
    if (aiFlag != null) {
      if (!mounted) return (proceed: false, overrideReason: null);
      final proceed = await showAiWarningDialog(context, aiFlag: aiFlag);
      return (proceed: proceed, overrideReason: null);
    }
    return (proceed: true, overrideReason: null);
  }

  Future<Map<String, dynamic>> _saveEntry(String? overrideReason) {
    return _isEdit
        ? MedThruApi.instance.updateMedication(
            widget.token,
            widget.existing!['id'] as int,
            name: _name.text.trim(),
            dosage: _dosage.text.trim(),
            frequency: _frequency.text.trim(),
            startDate: _startDate != null ? _fmt(_startDate!) : null,
            endDate: _endDate != null ? _fmt(_endDate!) : null,
            note: _note.text.trim(),
            overrideReason: overrideReason,
          )
        : MedThruApi.instance.addMedication(
            widget.token,
            name: _name.text.trim(),
            dosage: _dosage.text.trim(),
            frequency: _frequency.text.trim(),
            startDate: _startDate != null ? _fmt(_startDate!) : null,
            endDate: _endDate != null ? _fmt(_endDate!) : null,
            note: _note.text.trim(),
            overrideReason: overrideReason,
          );
  }

  /// Attempts the actual create/update call. If the server rejects it with
  /// a fresh hard stop the doctor never saw — the check-time and save-time
  /// states diverged, e.g. someone else just logged a new allergy — shows
  /// the same override dialog once and retries with the collected reason.
  /// Returns null if the doctor cancels out of that retry dialog.
  Future<Map<String, dynamic>?> _saveWithRetry(String? overrideReason) async {
    try {
      return await _saveEntry(overrideReason);
    } on ContraindicationBlockedException catch (blocked) {
      if (!mounted) return null;
      final reason = await showHardStopOverrideDialog(context, hardStops: blocked.hardStops);
      if (reason == null || !mounted) return null;
      return _saveEntry(reason);
    }
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Enter the medication name.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      String? overrideReason;
      if (MedThruApi.instance.isLoggedIn) {
        if (mounted) setState(() => _checkingInteractions = true);
        ({bool proceed, String? overrideReason}) checkResult;
        try {
          checkResult = await _runContraindicationCheck();
        } finally {
          if (mounted) setState(() => _checkingInteractions = false);
        }
        if (!checkResult.proceed) {
          if (mounted) setState(() => _saving = false);
          return;
        }
        overrideReason = checkResult.overrideReason;
      }
      final entry = await _saveWithRetry(overrideReason);
      if (entry == null) {
        if (mounted) setState(() => _saving = false);
        return;
      }
      await _applyReminder(entry['id'] as int);
      if (!mounted) return;
      Navigator.pop(context, entry);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
```

Note the `!_isEdit &&` exclusion on the `MedThruApi.instance.isLoggedIn`
check is gone — editing now runs the same check as creating.

- [ ] **Step 2: Rewrite `add_vaccination_screen.dart`'s check/save logic**

Replace the existing `_runContraindicationCheck` and `_save` methods:

```dart
  /// Doctor-only pre-check: cross-references this vaccine against the
  /// patient's logged allergies and active medications before it's saved.
  /// Returns false if the doctor cancels out of a warning; true otherwise
  /// (including when nothing was flagged at all).
  Future<bool> _runContraindicationCheck() async {
    final result = await MedThruApi.instance.checkContraindication(
      widget.token,
      treatmentType: 'vaccination',
      treatmentName: _vaccine.text.trim(),
    );
    final hardStops = (result['hardStops'] as List<dynamic>).cast<Map<String, dynamic>>();
    if (hardStops.isNotEmpty) {
      if (!mounted) return false;
      final reason = await showHardStopOverrideDialog(context, hardStops: hardStops);
      if (reason == null || !mounted) return false;
      await MedThruApi.instance.overrideContraindication(
        widget.token,
        ruleIds: hardStops.map((h) => h['ruleId'] as int).toList(),
        reason: reason,
        treatmentName: _vaccine.text.trim(),
      );
      return true;
    }
    final aiFlag = result['aiFlag'] as Map<String, dynamic>?;
    if (aiFlag != null) {
      if (!mounted) return false;
      return showAiWarningDialog(context, aiFlag: aiFlag);
    }
    return true;
  }

  Future<void> _save() async {
    if (_vaccine.text.trim().isEmpty) {
      setState(() => _error = 'Enter the vaccine name.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (!_isEdit && MedThruApi.instance.isLoggedIn) {
        if (mounted) setState(() => _checkingInteractions = true);
        bool proceed;
        try {
          proceed = await _runContraindicationCheck();
        } finally {
          if (mounted) setState(() => _checkingInteractions = false);
        }
        if (!proceed) {
          if (mounted) setState(() => _saving = false);
          return;
        }
      }
      final entry = _isEdit
          ? await MedThruApi.instance.updateVaccination(
              widget.token,
              widget.existing!['id'] as int,
              vaccine: _vaccine.text.trim(),
              administeredAt: _fmt(_administeredAt),
              doseNumber: int.tryParse(_doseNumber.text.trim()),
              nextDue: _nextDue != null ? _fmt(_nextDue!) : null,
              note: _note.text.trim(),
            )
          : await MedThruApi.instance.addVaccination(
              widget.token,
              vaccine: _vaccine.text.trim(),
              administeredAt: _fmt(_administeredAt),
              doseNumber: int.tryParse(_doseNumber.text.trim()),
              nextDue: _nextDue != null ? _fmt(_nextDue!) : null,
              note: _note.text.trim(),
            );
      if (!mounted) return;
      Navigator.pop(context, entry);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
```

with:

```dart
  /// Doctor-only pre-check: cross-references this vaccine against the
  /// patient's logged allergies and active medications before it's saved.
  /// `(proceed: false, ...)` means the doctor cancelled out of a warning.
  /// `overrideReason` is set when a hard stop was accepted with a typed
  /// reason — passed straight into the save/update call, which is what
  /// actually enforces and audits the override now, not this pre-check.
  Future<({bool proceed, String? overrideReason})> _runContraindicationCheck() async {
    final result = await MedThruApi.instance.checkContraindication(
      widget.token,
      treatmentType: 'vaccination',
      treatmentName: _vaccine.text.trim(),
    );
    final hardStops = (result['hardStops'] as List<dynamic>).cast<Map<String, dynamic>>();
    if (hardStops.isNotEmpty) {
      if (!mounted) return (proceed: false, overrideReason: null);
      final reason = await showHardStopOverrideDialog(context, hardStops: hardStops);
      if (reason == null || !mounted) return (proceed: false, overrideReason: null);
      return (proceed: true, overrideReason: reason);
    }
    final aiFlag = result['aiFlag'] as Map<String, dynamic>?;
    if (aiFlag != null) {
      if (!mounted) return (proceed: false, overrideReason: null);
      final proceed = await showAiWarningDialog(context, aiFlag: aiFlag);
      return (proceed: proceed, overrideReason: null);
    }
    return (proceed: true, overrideReason: null);
  }

  Future<Map<String, dynamic>> _saveEntry(String? overrideReason) {
    return _isEdit
        ? MedThruApi.instance.updateVaccination(
            widget.token,
            widget.existing!['id'] as int,
            vaccine: _vaccine.text.trim(),
            administeredAt: _fmt(_administeredAt),
            doseNumber: int.tryParse(_doseNumber.text.trim()),
            nextDue: _nextDue != null ? _fmt(_nextDue!) : null,
            note: _note.text.trim(),
            overrideReason: overrideReason,
          )
        : MedThruApi.instance.addVaccination(
            widget.token,
            vaccine: _vaccine.text.trim(),
            administeredAt: _fmt(_administeredAt),
            doseNumber: int.tryParse(_doseNumber.text.trim()),
            nextDue: _nextDue != null ? _fmt(_nextDue!) : null,
            note: _note.text.trim(),
            overrideReason: overrideReason,
          );
  }

  /// Attempts the actual create/update call. If the server rejects it with
  /// a fresh hard stop the doctor never saw — the check-time and save-time
  /// states diverged, e.g. someone else just logged a new allergy — shows
  /// the same override dialog once and retries with the collected reason.
  /// Returns null if the doctor cancels out of that retry dialog.
  Future<Map<String, dynamic>?> _saveWithRetry(String? overrideReason) async {
    try {
      return await _saveEntry(overrideReason);
    } on ContraindicationBlockedException catch (blocked) {
      if (!mounted) return null;
      final reason = await showHardStopOverrideDialog(context, hardStops: blocked.hardStops);
      if (reason == null || !mounted) return null;
      return _saveEntry(reason);
    }
  }

  Future<void> _save() async {
    if (_vaccine.text.trim().isEmpty) {
      setState(() => _error = 'Enter the vaccine name.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      String? overrideReason;
      if (MedThruApi.instance.isLoggedIn) {
        if (mounted) setState(() => _checkingInteractions = true);
        ({bool proceed, String? overrideReason}) checkResult;
        try {
          checkResult = await _runContraindicationCheck();
        } finally {
          if (mounted) setState(() => _checkingInteractions = false);
        }
        if (!checkResult.proceed) {
          if (mounted) setState(() => _saving = false);
          return;
        }
        overrideReason = checkResult.overrideReason;
      }
      final entry = await _saveWithRetry(overrideReason);
      if (entry == null) {
        if (mounted) setState(() => _saving = false);
        return;
      }
      if (!mounted) return;
      Navigator.pop(context, entry);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
```

- [ ] **Step 3: Verify it compiles**

Run: `cd app && flutter analyze lib/api.dart lib/screens/health_records/add_medication_screen.dart lib/screens/health_records/add_vaccination_screen.dart`
Expected: no errors.

- [ ] **Step 4: Manual verification**

No widget-test harness exists for these screens (established project
convention). Run: `cd app && flutter run -d windows` (or your usual target)

- As a doctor, add a medication named `Amoxicillin` for a patient with a
  logged Penicillin allergy → the blocking dialog appears; typing a reason
  and confirming saves it.
- Edit an existing, unrelated medication's name to `Amoxicillin` for that
  same patient → the same blocking dialog now appears on edit too (it
  didn't before this plan).
- Edit a medication without changing its name → saves immediately, no
  dialog (proves the self-exclusion holds from the UI side too, not just
  the API).
- Add an unrelated medication → saves immediately, no dialog.
- As a patient (not doctor-logged-in), add or edit a medication yourself →
  no dialog appears regardless of what you enter.

- [ ] **Step 5: Commit**

```bash
git add app/lib/screens/health_records/add_medication_screen.dart app/lib/screens/health_records/add_vaccination_screen.dart
git commit -m "Wire the enforced contraindication save/edit flow into both screens"
```
