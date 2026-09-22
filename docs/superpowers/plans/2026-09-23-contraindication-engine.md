# Triage Contraindication Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cross-reference a proposed medication or vaccination against a patient's logged allergies and active medications, and flag a dangerous interaction before a doctor saves it.

**Architecture:** A deterministic hard-stop rule table (`contraindication_rules`) is checked first, matched by a pure keyword-matching module; a Gemini judgment layer runs only when the hard-stop layer finds nothing, mirroring how `reschedule.js`/`gemini.js` split deterministic decisions from AI narration. Hard stops block the doctor's save until they type an override reason (audited); Gemini flags are a dismissible warning.

**Tech Stack:** Node.js (`node:sqlite`, Express 5), `@google/genai`, Flutter/Dart.

## Global Constraints

- No raw clinical history beyond the current allergy/medication lists is ever sent to Gemini — no notes, no lab results, no diagnoses (per spec's non-goals).
- A Gemini outage/timeout/missing key must never block saving a treatment — `judgeContraindication` always degrades to `null`, never throws (same invariant as `gemini.js`'s `rationalizeCandidates`).
- The hard-stop layer never depends on network access and can never be silently overridden by Gemini.
- Only checked for a doctor proposing a *new* treatment (`MedThruApi.instance.isLoggedIn` / `req.doctor` present) — never for a patient's own self-reported entries, and never on edits to an existing entry.
- Model/timeout reuse `gemini-flash-lite-latest` / 10000ms, matching `gemini.js`'s already-tuned values.

Full design context: `docs/superpowers/specs/2026-09-23-contraindication-engine-design.md`.

---

### Task 1: `contraindication_rules` table and seed data

**Files:**
- Modify: `db.js` (insert a new block right before `module.exports = db;` on the line currently reading `module.exports = db;`, i.e. after the closing `}` of the "Migration 2: plaintext patients.token -> hashed cards table" block)

**Interfaces:**
- Produces: a `contraindication_rules` table with columns `id, rule_type ('allergy'|'medication'), trigger_terms (TEXT, comma-separated), treatment_terms (TEXT, comma-separated), severity (TEXT), reason (TEXT), created_by (INTEGER, nullable), created_at, updated_at`, seeded with 15 rows on first boot (empty-table seed, same pattern as the `clinics` seed near the top of `db.js`).

- [ ] **Step 1: Add the table creation and seed block to `db.js`**

Insert this immediately before the final `module.exports = db;` line:

```js
// --- Contraindication engine: hard-stop rule table ---
//
// A small curated set of well-known, high-severity allergy/medication
// conflicts, checked deterministically before a doctor saves a new
// medication or vaccination (see contraindication.js and server.js's
// "Contraindication engine" section). Gemini judgment is layered on top of
// this table in server.js, never a replacement for it.
db.exec(`
  CREATE TABLE IF NOT EXISTS contraindication_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    rule_type TEXT NOT NULL,            -- 'allergy' | 'medication'
    trigger_terms TEXT NOT NULL,        -- comma-separated keywords matched
                                         -- against an existing allergen or
                                         -- active medication name
    treatment_terms TEXT NOT NULL,      -- comma-separated keywords matched
                                         -- against the proposed treatment name
    severity TEXT NOT NULL DEFAULT 'high',
    reason TEXT NOT NULL,
    created_by INTEGER REFERENCES doctors(id),
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
  );
`);

// --- Seed: a starter set of well-known hard-stop rules ---
{
  const { n } = db.prepare(`SELECT COUNT(*) AS n FROM contraindication_rules`).get();
  if (n === 0) {
    const insert = db.prepare(
      `INSERT INTO contraindication_rules (rule_type, trigger_terms, treatment_terms, severity, reason)
       VALUES (?, ?, ?, ?, ?)`
    );
    const seed = [
      ['allergy', 'penicillin,amoxicillin,ampicillin,augmentin',
        'penicillin,amoxicillin,ampicillin,augmentin,piperacillin', 'high',
        'Penicillin-class allergy cross-reacts with all penicillin-class antibiotics and can cause a severe or anaphylactic reaction.'],
      ['allergy', 'sulfa,sulfonamide,bactrim,sulfamethoxazole',
        'sulfamethoxazole,bactrim,co-trimoxazole,sulfasalazine', 'high',
        'Sulfa allergy cross-reacts with sulfonamide antibiotics and can trigger a severe skin or systemic reaction.'],
      ['allergy', 'aspirin,nsaid,ibuprofen,naproxen',
        'ibuprofen,naproxen,aspirin,diclofenac,ketorolac', 'high',
        'NSAID/aspirin allergy cross-reacts across the NSAID class and can trigger bronchospasm or anaphylaxis.'],
      ['allergy', 'egg,eggs',
        'influenza vaccine,flu vaccine,yellow fever vaccine', 'moderate',
        'Some influenza and yellow fever vaccines are egg-based and can trigger a reaction in an egg-allergic patient.'],
      ['allergy', 'gelatin',
        'mmr,measles mumps rubella,varicella,chickenpox vaccine', 'moderate',
        'MMR and varicella vaccines contain gelatin as a stabilizer, which can trigger a reaction in a gelatin-allergic patient.'],
      ['medication', 'warfarin,coumadin',
        'ibuprofen,naproxen,aspirin,diclofenac', 'high',
        'Combining warfarin with NSAIDs significantly increases bleeding risk.'],
      ['medication', 'warfarin,coumadin',
        'ciprofloxacin,metronidazole,fluconazole', 'high',
        'These antibiotics/antifungals inhibit warfarin metabolism, increasing INR and bleeding risk.'],
      ['medication', 'warfarin,coumadin',
        'amiodarone', 'high',
        'Amiodarone inhibits warfarin metabolism, sharply increasing INR and bleeding risk.'],
      ['medication', 'phenelzine,tranylcypromine,isocarboxazid',
        'sertraline,fluoxetine,paroxetine,pseudoephedrine,phenylephrine', 'high',
        'Combining an MAOI with an SSRI or decongestant risks serotonin syndrome or a hypertensive crisis.'],
      ['medication', 'simvastatin,atorvastatin,lovastatin',
        'clarithromycin,erythromycin,itraconazole', 'high',
        'These interactions raise statin blood levels and significantly increase the risk of rhabdomyolysis.'],
      ['medication', 'methotrexate',
        'ibuprofen,naproxen,aspirin', 'moderate',
        'NSAIDs reduce methotrexate clearance, increasing the risk of methotrexate toxicity.'],
      ['medication', 'lithium',
        'ibuprofen,naproxen,diclofenac', 'moderate',
        'NSAIDs reduce renal clearance of lithium, risking lithium toxicity.'],
      ['medication', 'lisinopril,enalapril,ramipril',
        'spironolactone,potassium chloride,potassium supplement', 'moderate',
        'Combining an ACE inhibitor with a potassium-sparing agent risks dangerous hyperkalemia.'],
      ['medication', 'clopidogrel,plavix',
        'omeprazole,esomeprazole', 'moderate',
        'Omeprazole/esomeprazole can inhibit clopidogrel activation, reducing its antiplatelet effect.'],
      ['medication', 'digoxin',
        'clarithromycin,erythromycin,amiodarone', 'high',
        'These drugs raise digoxin levels, risking digoxin toxicity.'],
    ];
    for (const row of seed) insert.run(...row);
    console.log(`Seeded ${seed.length} contraindication rules.`);
  }
}
```

- [ ] **Step 2: Verify the migration runs cleanly**

`db.js` has no dedicated migration test harness in this project (migrations are exercised end-to-end via `test/smoke.js`, not unit tested in isolation). Sanity-check it manually:

Run: `node -e "require('./db'); const { DatabaseSync } = require('node:sqlite'); const db = new DatabaseSync('medthru.db'); console.log(db.prepare('SELECT COUNT(*) AS n FROM contraindication_rules').get());"`

Expected: `{ n: 15 }` (or a multiple of your local test runs if the DB already had rows — if you're testing against a fresh/wiped `medthru.db`, expect exactly 15). Running it a second time should not add duplicate rows (the seed only fires when the table is empty).

- [ ] **Step 3: Commit**

```bash
git add db.js
git commit -m "Add the contraindication_rules table and starter rule set"
```

---

### Task 2: Deterministic hard-stop matching engine

**Files:**
- Create: `contraindication.js`
- Test: `test/contraindication.js`

**Interfaces:**
- Consumes: nothing (pure function, no DB/network — takes plain data).
- Produces: `checkHardStops({ rules, allergies, medications, proposedName }) -> Array<{ ruleId, severity, reason, triggerSource: 'allergy'|'medication', triggerLabel, matchedTreatmentTerm }>` and `splitTerms(text) -> string[]`, exported from `contraindication.js`. `rules` is shaped like rows from Task 1's table; `allergies` is `[{ allergen }]`; `medications` is `[{ name }]` (caller's responsibility to pre-filter to active ones).

- [ ] **Step 1: Write the failing tests**

Create `test/contraindication.js`:

```js
// Unit tests for the deterministic hard-stop matching engine. No DB, no
// network — plain functions, hand-built inputs.
'use strict';

const assert = require('node:assert');
const { checkHardStops } = require('../contraindication');

function check(condition, message) {
  assert.ok(condition, message);
  console.log(`ok - ${message}`);
}

const penicillinRule = {
  id: 1,
  rule_type: 'allergy',
  trigger_terms: 'penicillin,amoxicillin',
  treatment_terms: 'amoxicillin,ampicillin',
  severity: 'high',
  reason: 'Penicillin-class cross-reactivity.',
};

const warfarinRule = {
  id: 2,
  rule_type: 'medication',
  trigger_terms: 'warfarin',
  treatment_terms: 'ibuprofen,naproxen',
  severity: 'high',
  reason: 'Bleeding risk.',
};

// --- allergy rule matches ---
const allergyMatch = checkHardStops({
  rules: [penicillinRule],
  allergies: [{ allergen: 'Penicillin' }],
  medications: [],
  proposedName: 'Amoxicillin 500mg',
});
check(allergyMatch.length === 1, 'a penicillin allergy flags amoxicillin');
check(allergyMatch[0].ruleId === 1, 'the match reports the matching rule id');
check(allergyMatch[0].triggerSource === 'allergy', 'the match reports its trigger source');
check(allergyMatch[0].triggerLabel === 'Penicillin', 'the match reports the actual allergen text that matched');

// --- case-insensitivity ---
const caseInsensitive = checkHardStops({
  rules: [penicillinRule],
  allergies: [{ allergen: 'PENICILLIN' }],
  medications: [],
  proposedName: 'amoxicillin',
});
check(caseInsensitive.length === 1, 'matching is case-insensitive on both sides');

// --- medication-vs-medication rule matches ---
const medMatch = checkHardStops({
  rules: [warfarinRule],
  allergies: [],
  medications: [{ name: 'Warfarin' }],
  proposedName: 'Ibuprofen 200mg',
});
check(medMatch.length === 1, 'an existing warfarin prescription flags ibuprofen');
check(medMatch[0].triggerSource === 'medication', 'a medication-vs-medication match reports the medication trigger source');

// --- no match when only one side hits ---
const onlyAllergySide = checkHardStops({
  rules: [penicillinRule],
  allergies: [{ allergen: 'Penicillin' }],
  medications: [],
  proposedName: 'Paracetamol',
});
check(onlyAllergySide.length === 0, 'no match when the proposed treatment does not hit the trigger rule at all');

const onlyTreatmentSide = checkHardStops({
  rules: [penicillinRule],
  allergies: [{ allergen: 'Pollen' }],
  medications: [],
  proposedName: 'Amoxicillin',
});
check(onlyTreatmentSide.length === 0, 'no match when the patient has no matching allergy/medication on file');

// --- multiple rules matching at once ---
const multiRule = checkHardStops({
  rules: [penicillinRule, warfarinRule],
  allergies: [{ allergen: 'Penicillin' }],
  medications: [{ name: 'Warfarin' }],
  proposedName: 'Amoxicillin and Ibuprofen combo',
});
check(multiRule.length === 2, 'multiple independently-matching rules all get reported');

// --- one entry per matching rule, even with multiple matching records ---
const duplicateAllergies = checkHardStops({
  rules: [penicillinRule],
  allergies: [{ allergen: 'Penicillin' }, { allergen: 'Amoxicillin' }],
  medications: [],
  proposedName: 'Ampicillin',
});
check(duplicateAllergies.length === 1,
  'a rule is reported once even if more than one logged allergy matches it');

// --- checkHardStops trusts whatever `medications` list it is given ---
const trustsCallerFiltering = checkHardStops({
  rules: [warfarinRule],
  allergies: [],
  medications: [{ name: 'Warfarin' }], // caller decides whether this is "active"
  proposedName: 'Naproxen',
});
check(trustsCallerFiltering.length === 1,
  'checkHardStops matches whatever medications list it is given, trusting the caller to have already filtered to active ones');

console.log('All contraindication tests passed.');
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `node test/contraindication.js`
Expected: `Error: Cannot find module '../contraindication'`

- [ ] **Step 3: Write the implementation**

Create `contraindication.js`:

```js
/// Deterministic hard-stop matching for the triage contraindication engine.
///
/// Pure and synchronous — no DB or network access — so it's trivial to unit
/// test with hand-built inputs. See its sibling, contraindication-gemini.js,
/// for the softer, AI-judged layer that sits on top of this.

function splitTerms(text) {
  return String(text || '')
    .split(',')
    .map((t) => t.trim().toLowerCase())
    .filter(Boolean);
}

function anyTermMatches(terms, haystack) {
  const text = String(haystack || '').toLowerCase();
  return terms.some((term) => text.includes(term));
}

/// Checks a proposed treatment name against the patient's allergies and
/// active medications, using `rules` (rows shaped like the
/// `contraindication_rules` table: `rule_type`, `trigger_terms`,
/// `treatment_terms`, `severity`, `reason`).
///
/// `allergies` is `[{ allergen }]`, `medications` is `[{ name }]` — already
/// filtered by the caller to whatever's clinically relevant (e.g. active
/// medications only). Returns one entry per matching rule, even if more than
/// one of the patient's allergies/medications would have matched it.
function checkHardStops({ rules, allergies, medications, proposedName }) {
  const matches = [];

  for (const rule of rules) {
    const treatmentTerms = splitTerms(rule.treatment_terms);
    const matchedTreatmentTerm = treatmentTerms.find((term) =>
      String(proposedName || '').toLowerCase().includes(term)
    );
    if (!matchedTreatmentTerm) continue;

    const triggerTerms = splitTerms(rule.trigger_terms);
    const sourceList = rule.rule_type === 'allergy' ? allergies : medications;
    const sourceField = rule.rule_type === 'allergy' ? 'allergen' : 'name';

    const triggerLabel = sourceList
      .map((item) => item[sourceField])
      .find((label) => anyTermMatches(triggerTerms, label));

    if (triggerLabel) {
      matches.push({
        ruleId: rule.id,
        severity: rule.severity,
        reason: rule.reason,
        triggerSource: rule.rule_type,
        triggerLabel,
        matchedTreatmentTerm,
      });
    }
  }

  return matches;
}

module.exports = { checkHardStops, splitTerms };
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `node test/contraindication.js`
Expected: every `ok - ...` line prints, ending with `All contraindication tests passed.`

- [ ] **Step 5: Commit**

```bash
git add contraindication.js test/contraindication.js
git commit -m "Add the deterministic contraindication hard-stop matching engine"
```

---

### Task 3: Gemini judgment layer

**Files:**
- Create: `contraindication-gemini.js`
- Test: `test/contraindication-gemini.js`

**Interfaces:**
- Consumes: `@google/genai`'s `GoogleGenAI` (already a project dependency, used by `gemini.js`).
- Produces: `judgeContraindication({ allergies, medications, proposedTreatment }, { genAI, timeoutMs }) -> Promise<{ severity: 'low'|'moderate'|'high', reason: string } | null>` from `contraindication-gemini.js`. `allergies` is `[{ allergen, reaction, severity }]`, `medications` is `[{ name, dosage, frequency }]`, `proposedTreatment` is `{ name, type: 'medication'|'vaccination', dosage }`.

- [ ] **Step 1: Write the failing tests**

Create `test/contraindication-gemini.js`:

```js
// Unit tests for the Gemini contraindication-judgment wrapper. No real
// network call — a fake client is injected so these run offline and fast.
// The invariant worth proving: this module never throws, and "not flagged"
// collapses to the same `null` shape as any failure.
'use strict';

const assert = require('node:assert');
const { judgeContraindication } = require('../contraindication-gemini');

function check(condition, message) {
  assert.ok(condition, message);
  console.log(`ok - ${message}`);
}

const context = {
  allergies: [{ allergen: 'Penicillin', reaction: 'Hives', severity: 'Moderate' }],
  medications: [{ name: 'Metformin', dosage: '500mg', frequency: 'Twice daily' }],
  proposedTreatment: { name: 'Ibuprofen', type: 'medication', dosage: '200mg' },
};

async function main() {
  delete process.env.GEMINI_API_KEY;
  const noKey = await judgeContraindication(context);
  check(noKey === null, 'no API key -> null, no network attempt');

  const flaggedClient = {
    models: {
      generateContent: async () => ({
        text: JSON.stringify({
          flagged: true,
          severity: 'moderate',
          reason: 'NSAIDs can worsen kidney function in some diabetic patients.',
        }),
      }),
    },
  };
  const flagged = await judgeContraindication(context, { genAI: flaggedClient });
  check(flagged !== null && flagged.severity === 'moderate' && flagged.reason.length > 0,
    'a well-formed flagged response returns severity and reason');

  const clearClient = {
    models: {
      generateContent: async () => ({
        text: JSON.stringify({ flagged: false, severity: 'low', reason: '' }),
      }),
    },
  };
  const clear = await judgeContraindication(context, { genAI: clearClient });
  check(clear === null, 'a well-formed but not-flagged response returns null, same as a clean bill of health');

  const throwingClient = {
    models: { generateContent: async () => { throw new Error('network down'); } },
  };
  const thrown = await judgeContraindication(context, { genAI: throwingClient });
  check(thrown === null, 'a thrown error resolves to null, not a rejected promise');

  const hangingClient = {
    models: { generateContent: () => new Promise(() => {}) },
  };
  const start = Date.now();
  const timedOut = await judgeContraindication(context, { genAI: hangingClient, timeoutMs: 200 });
  check(timedOut === null, 'a hanging call times out to null');
  check(Date.now() - start < 1000, 'the timeout fires close to the configured delay, not the default');

  const malformedClient = {
    models: { generateContent: async () => ({ text: '{"not": "the expected shape"}' }) },
  };
  const malformed = await judgeContraindication(context, { genAI: malformedClient });
  check(malformed === null, 'a malformed response resolves to null');

  const badSeverityClient = {
    models: {
      generateContent: async () => ({
        text: JSON.stringify({ flagged: true, severity: 'catastrophic', reason: 'x' }),
      }),
    },
  };
  const badSeverity = await judgeContraindication(context, { genAI: badSeverityClient });
  check(badSeverity === null, 'a severity outside the enum resolves to null rather than being trusted');

  console.log('All contraindication-gemini tests passed.');
}

main();
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `node test/contraindication-gemini.js`
Expected: `Error: Cannot find module '../contraindication-gemini'`

- [ ] **Step 3: Write the implementation**

Create `contraindication-gemini.js`:

```js
/// Thin wrapper around the Gemini API for judging whether a proposed
/// medication/vaccination is dangerous given a patient's logged allergies
/// and active medications. Only ever consulted by server.js once the
/// deterministic hard-stop table (contraindication.js) has found nothing —
/// this layer is a softer, non-authoritative second opinion, never the
/// decision-maker for a hard block. Degrades to `null` (never throws) on
/// any failure, timeout, missing key, or a "not flagged" verdict — the
/// caller treats all three identically: nothing to warn about.
const { GoogleGenAI } = require('@google/genai');

const MODEL = 'gemini-flash-lite-latest';
const DEFAULT_TIMEOUT_MS = 10000;
const VALID_SEVERITIES = ['low', 'moderate', 'high'];

let cachedClient = null;
function defaultClient() {
  if (!process.env.GEMINI_API_KEY) return null;
  if (!cachedClient) {
    cachedClient = new GoogleGenAI({ apiKey: process.env.GEMINI_API_KEY });
  }
  return cachedClient;
}

const RESPONSE_SCHEMA = {
  type: 'object',
  properties: {
    flagged: { type: 'boolean' },
    severity: { type: 'string', enum: VALID_SEVERITIES },
    reason: { type: 'string' },
  },
  required: ['flagged', 'severity', 'reason'],
};

function buildPrompt({ allergies, medications, proposedTreatment }) {
  const allergyLines = allergies.length
    ? allergies.map((a) =>
        `- ${a.allergen}${a.reaction ? ` (reaction: ${a.reaction})` : ''}${a.severity ? ` [${a.severity}]` : ''}`)
    : ['- None logged'];
  const medicationLines = medications.length
    ? medications.map((m) => `- ${m.name}${m.dosage ? ` ${m.dosage}` : ''}${m.frequency ? `, ${m.frequency}` : ''}`)
    : ['- None logged'];

  return [
    `A doctor is about to give a patient the following ${proposedTreatment.type}: ` +
      `${proposedTreatment.name}${proposedTreatment.dosage ? ` (${proposedTreatment.dosage})` : ''}.`,
    'The patient has these logged allergies:',
    ...allergyLines,
    'The patient is on these active medications:',
    ...medicationLines,
    'Judge whether this proposed treatment could be dangerous given the allergies and',
    'medications listed above. Only flag a genuine, clinically meaningful concern — not a',
    'generic caution. If flagged, give a severity (low, moderate, or high) and a short',
    '(under 30 words) reason referencing only the allergies/medications listed above.',
    'Do not invent allergies or medications that are not listed.',
  ].join('\n');
}

/// Returns `{ severity, reason }` if Gemini judges the proposed treatment
/// dangerous, or `null` if it doesn't, if Gemini is unconfigured/unreachable/
/// too slow, or if the response doesn't parse into the expected shape.
///
/// `genAI`/`timeoutMs` are injectable for testing without a real API key or
/// a real multi-second wait.
async function judgeContraindication(
  { allergies, medications, proposedTreatment },
  { genAI = defaultClient(), timeoutMs = DEFAULT_TIMEOUT_MS } = {},
) {
  if (!genAI) return null;

  let timer;
  try {
    const response = await Promise.race([
      genAI.models.generateContent({
        model: MODEL,
        contents: buildPrompt({ allergies, medications, proposedTreatment }),
        config: {
          responseMimeType: 'application/json',
          responseSchema: RESPONSE_SCHEMA,
        },
      }),
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('Gemini timeout')), timeoutMs);
      }),
    ]);

    const parsed = JSON.parse(response.text);
    if (typeof parsed.flagged !== 'boolean') return null;
    if (!parsed.flagged) return null;
    if (!VALID_SEVERITIES.includes(parsed.severity)) return null;
    if (typeof parsed.reason !== 'string' || !parsed.reason.trim()) return null;

    return { severity: parsed.severity, reason: parsed.reason };
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

module.exports = { judgeContraindication, buildPrompt };
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `node test/contraindication-gemini.js`
Expected: every `ok - ...` line prints, ending with `All contraindication-gemini tests passed.`

- [ ] **Step 5: Commit**

```bash
git add contraindication-gemini.js test/contraindication-gemini.js
git commit -m "Add the Gemini contraindication-judgment layer"
```

---

### Task 4: Check and override API endpoints

**Files:**
- Modify: `server.js:31` (add requires), `server.js` (new section right after the `lab-results` `registerHealthRecords` call, before the `// --- Documents ---` comment)
- Modify: `test/smoke.js` (extend, before the final `console.log('\nAll smoke checks passed.');`)

**Interfaces:**
- Consumes: `checkHardStops` from `contraindication.js` (Task 2), `judgeContraindication` from `contraindication-gemini.js` (Task 3), the `contraindication_rules` table (Task 1), and `server.js`'s existing `resolvePatientFromReq`, `logAudit`, `requireDoctor`, `lookupLimiter`.
- Produces: `POST /api/patients/token/:token/contraindication-check` -> `{ hardStops: [...], aiFlag: {...} | null }`; `POST /api/patients/token/:token/contraindication-override` -> `201 { logged: true }`.

- [ ] **Step 1: Add the module requires**

In `server.js`, right after line 31 (`const { rationalizeCandidates, orderedStartsAts } = require('./gemini');`), add:

```js
const { checkHardStops } = require('./contraindication');
const { judgeContraindication } = require('./contraindication-gemini');
```

- [ ] **Step 2: Add the endpoints**

Find the `registerHealthRecords({ path: 'lab-results', ... });` call (it ends with `});` right before the `// --- Documents ---` comment). Insert this new section between them:

```js
// --- Contraindication engine ---
//
// Cross-references a proposed medication or vaccination against the
// patient's logged allergies and active medications before it's saved. A
// deterministic hard-stop rule table (contraindication_rules) always runs
// first and can never be silently overridden; Gemini only judges the softer
// cases left over once the hard-stop table finds nothing (see
// contraindication.js / contraindication-gemini.js). Doctor-only: this is
// about a doctor proposing a *new* treatment, not a patient's own
// self-reported entries.

const TREATMENT_TYPES = ['medication', 'vaccination'];

function activeMedicationNames(patientId) {
  return db.prepare(
    `SELECT name FROM medications
     WHERE patient_id = ? AND (end_date IS NULL OR end_date >= date('now'))`
  ).all(patientId);
}

function activeMedicationsDetailed(patientId) {
  return db.prepare(
    `SELECT name, dosage, frequency FROM medications
     WHERE patient_id = ? AND (end_date IS NULL OR end_date >= date('now'))`
  ).all(patientId);
}

app.post('/api/patients/token/:token/contraindication-check', lookupLimiter, requireDoctor, async (req, res) => {
  const patient = resolvePatientFromReq(req);
  if (!patient) {
    return res.status(404).json({ error: 'No patient found for this card' });
  }

  const { treatmentType, treatmentName, dosage } = req.body;
  if (!TREATMENT_TYPES.includes(treatmentType)) {
    return res.status(400).json({ error: `treatmentType must be one of: ${TREATMENT_TYPES.join(', ')}` });
  }
  if (typeof treatmentName !== 'string' || !treatmentName.trim()) {
    return res.status(400).json({ error: 'treatmentName is required' });
  }

  const allergenRows = db.prepare(`SELECT allergen FROM allergies WHERE patient_id = ?`).all(patient.id);
  const rules = db.prepare(`SELECT * FROM contraindication_rules`).all();

  const hardStops = checkHardStops({
    rules,
    allergies: allergenRows,
    medications: activeMedicationNames(patient.id),
    proposedName: treatmentName,
  });

  let aiFlag = null;
  if (hardStops.length === 0) {
    aiFlag = await judgeContraindication({
      allergies: db.prepare(`SELECT allergen, reaction, severity FROM allergies WHERE patient_id = ?`).all(patient.id),
      medications: activeMedicationsDetailed(patient.id),
      proposedTreatment: { name: treatmentName, type: treatmentType, dosage: dosage || null },
    });
  }

  if (hardStops.length > 0 || aiFlag) {
    logAudit(patient.id, req.doctor.id, 'contraindication_flagged', JSON.stringify({
      treatmentType,
      treatmentName,
      hardStopRuleIds: hardStops.map((h) => h.ruleId),
      aiFlag,
    }));
  }

  res.json({ hardStops, aiFlag });
});

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

- [ ] **Step 3: Extend `test/smoke.js`**

In `test/smoke.js`, insert this block right before the line `console.log('\nAll smoke checks passed.');` (it can reuse the `cardToken`, `patient`, and `token` variables already in scope from earlier in `main()`):

```js
    // --- Contraindication engine: check + override ---
    res = await fetch(`${BASE}/patients/token/${cardToken}/contraindication-check`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ treatmentType: 'medication', treatmentName: 'Amoxicillin' }),
    });
    assert(res.status === 200, 'contraindication check succeeds');
    const amoxCheck = await res.json();
    assert(amoxCheck.hardStops.length > 0, 'amoxicillin is flagged for a patient with a logged penicillin allergy');
    assert(amoxCheck.hardStops[0].reason.length > 0, 'the hard stop carries a human-readable reason');
    assert(amoxCheck.aiFlag === null, 'the AI layer is skipped once a hard stop already fired');

    res = await fetch(`${BASE}/patients/token/${cardToken}/contraindication-check`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ treatmentType: 'medication', treatmentName: 'Paracetamol' }),
    });
    assert(res.status === 200, 'contraindication check succeeds for an unrelated medication');
    const clearCheck = await res.json();
    assert(clearCheck.hardStops.length === 0, 'paracetamol is not flagged for this patient');
    assert(clearCheck.aiFlag === null, 'no GEMINI_API_KEY is configured in CI, so the AI layer stays null rather than erroring');

    res = await fetch(`${BASE}/patients/token/${cardToken}/contraindication-check`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ treatmentType: 'medication', treatmentName: 'Amoxicillin' }),
    });
    assert(res.status === 401, 'the contraindication check requires a doctor bearer token');

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

    res = await fetch(`${BASE}/patients/${patient.id}/audit`);
    const auditEntries = await res.json();
    assert(auditEntries.some((a) => a.action === 'contraindication_override'),
      'the override is written to the audit log');
    assert(auditEntries.some((a) => a.action === 'contraindication_flagged'),
      'the flagged check itself is also written to the audit log');

```

- [ ] **Step 4: Run the smoke test to verify it passes**

Run: `npm test`
Expected: all existing checks plus the new `ok - ...` lines above pass, ending with `All smoke checks passed.`

- [ ] **Step 5: Commit**

```bash
git add server.js test/smoke.js
git commit -m "Add the contraindication check and override API endpoints"
```

---

### Task 5: Admin CRUD endpoints for rules

**Files:**
- Modify: `server.js` (append to the "Contraindication engine" section added in Task 4, right after the `/contraindication-override` route)
- Modify: `test/smoke.js` (extend, right after Task 4's new block)

**Interfaces:**
- Consumes: `requireDoctor`, `requireAdmin` (existing `server.js` middleware), the `contraindication_rules` table (Task 1).
- Produces: `GET /api/contraindication-rules` -> `Array<rule>`; `POST /api/contraindication-rules` -> `201 rule`; `PUT /api/contraindication-rules/:id` -> `rule`; `DELETE /api/contraindication-rules/:id` -> `{ deleted: true }`. A `rule` object has every column from the Task 1 table.

- [ ] **Step 1: Add the endpoints**

Append this to the end of the "Contraindication engine" section in `server.js` (right after the `/contraindication-override` route added in Task 4):

```js
app.get('/api/contraindication-rules', requireDoctor, (_req, res) => {
  res.json(db.prepare(`SELECT * FROM contraindication_rules ORDER BY rule_type, id`).all());
});

function contraindicationRuleError({ ruleType, triggerTerms, treatmentTerms, reason }) {
  if (!['allergy', 'medication'].includes(ruleType)) {
    return `ruleType must be 'allergy' or 'medication'`;
  }
  if (typeof triggerTerms !== 'string' || !triggerTerms.trim()) {
    return 'triggerTerms is required';
  }
  if (typeof treatmentTerms !== 'string' || !treatmentTerms.trim()) {
    return 'treatmentTerms is required';
  }
  if (typeof reason !== 'string' || !reason.trim()) {
    return 'reason is required';
  }
  return null;
}

app.post('/api/contraindication-rules', requireDoctor, requireAdmin, (req, res) => {
  const problem = contraindicationRuleError(req.body);
  if (problem) return res.status(400).json({ error: problem });

  const { ruleType, triggerTerms, treatmentTerms, severity, reason } = req.body;
  const result = db.prepare(
    `INSERT INTO contraindication_rules (rule_type, trigger_terms, treatment_terms, severity, reason, created_by)
     VALUES (?, ?, ?, ?, ?, ?)`
  ).run(ruleType, triggerTerms.trim(), treatmentTerms.trim(), severity || 'high', reason.trim(), req.doctor.id);

  res.status(201).json(
    db.prepare(`SELECT * FROM contraindication_rules WHERE id = ?`).get(Number(result.lastInsertRowid))
  );
});

app.put('/api/contraindication-rules/:id', requireDoctor, requireAdmin, (req, res) => {
  const existing = db.prepare(`SELECT * FROM contraindication_rules WHERE id = ?`).get(req.params.id);
  if (!existing) {
    return res.status(404).json({ error: 'Rule not found' });
  }

  const problem = contraindicationRuleError(req.body);
  if (problem) return res.status(400).json({ error: problem });

  const { ruleType, triggerTerms, treatmentTerms, severity, reason } = req.body;
  db.prepare(
    `UPDATE contraindication_rules
     SET rule_type = ?, trigger_terms = ?, treatment_terms = ?, severity = ?, reason = ?, updated_at = datetime('now')
     WHERE id = ?`
  ).run(ruleType, triggerTerms.trim(), treatmentTerms.trim(), severity || 'high', reason.trim(), existing.id);

  res.json(db.prepare(`SELECT * FROM contraindication_rules WHERE id = ?`).get(existing.id));
});

app.delete('/api/contraindication-rules/:id', requireDoctor, requireAdmin, (req, res) => {
  const existing = db.prepare(`SELECT * FROM contraindication_rules WHERE id = ?`).get(req.params.id);
  if (!existing) {
    return res.status(404).json({ error: 'Rule not found' });
  }
  db.prepare(`DELETE FROM contraindication_rules WHERE id = ?`).run(existing.id);
  res.json({ deleted: true });
});
```

- [ ] **Step 2: Extend `test/smoke.js`**

Append this right after Task 4's new block (still before `console.log('\nAll smoke checks passed.');`):

```js
    // --- Contraindication engine: admin-only rule CRUD ---
    res = await fetch(`${BASE}/contraindication-rules`, { headers: { Authorization: `Bearer ${token}` } });
    assert(res.status === 200, 'any doctor can list contraindication rules');
    const seededRules = await res.json();
    assert(seededRules.length >= 15, 'the starter rule set is seeded on first boot');

    res = await fetch(`${BASE}/contraindication-rules`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({
        ruleType: 'medication',
        triggerTerms: 'test-trigger',
        treatmentTerms: 'test-treatment',
        severity: 'moderate',
        reason: 'CI test rule.',
      }),
    });
    assert(res.status === 403, 'a non-admin doctor cannot create a contraindication rule');

    // Promote CI Doctor to admin directly — no API surface for this, same
    // direct-DB approach already used earlier in this file for the doctor
    // per-clinic index test.
    {
      const { DatabaseSync } = require('node:sqlite');
      const promoteDb = new DatabaseSync(DB_PATH);
      promoteDb.prepare(`UPDATE doctors SET is_admin = 1 WHERE email = ?`).run('ci@medthru.test');
      promoteDb.close();
    }

    res = await fetch(`${BASE}/contraindication-rules`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({
        ruleType: 'medication',
        triggerTerms: 'test-trigger',
        treatmentTerms: 'test-treatment',
        severity: 'moderate',
        reason: 'CI test rule.',
      }),
    });
    assert(res.status === 201, 'an admin doctor can create a contraindication rule');
    const newRule = await res.json();

    res = await fetch(`${BASE}/contraindication-rules/${newRule.id}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({
        ruleType: 'medication',
        triggerTerms: 'test-trigger',
        treatmentTerms: 'test-treatment-edited',
        severity: 'high',
        reason: 'CI test rule, edited.',
      }),
    });
    assert(res.status === 200, 'an admin doctor can edit a contraindication rule');
    const editedRule = await res.json();
    assert(editedRule.treatment_terms === 'test-treatment-edited', 'the edit is reflected in the response');

    res = await fetch(`${BASE}/contraindication-rules/${newRule.id}`, {
      method: 'DELETE',
      headers: { Authorization: `Bearer ${token}` },
    });
    assert(res.status === 200, 'an admin doctor can delete a contraindication rule');

```

- [ ] **Step 3: Run the smoke test to verify it passes**

Run: `npm test`
Expected: all checks pass, ending with `All smoke checks passed.`

- [ ] **Step 4: Commit**

```bash
git add server.js test/smoke.js
git commit -m "Add admin CRUD endpoints for contraindication rules"
```

---

### Task 6: Flutter API client methods

**Files:**
- Modify: `app/lib/api.dart` (insert after `deleteVaccination`, before `getMedicalHistory`, around line 634-636)

**Interfaces:**
- Consumes: the endpoints from Tasks 4 and 5.
- Produces: `MedThruApi.instance.checkContraindication(token, {treatmentType, treatmentName, dosage}) -> Future<Map<String,dynamic>>` (shape `{hardStops, aiFlag}`); `.overrideContraindication(token, {ruleIds, reason, treatmentName}) -> Future<void>`; `.getContraindicationRules() -> Future<List<Map<String,dynamic>>>`; `.createContraindicationRule({ruleType, triggerTerms, treatmentTerms, severity, reason}) -> Future<Map<String,dynamic>>`; `.updateContraindicationRule(id, {...same fields...}) -> Future<Map<String,dynamic>>`; `.deleteContraindicationRule(id) -> Future<void>`.

- [ ] **Step 1: Add the client methods**

In `app/lib/api.dart`, insert this block right after `deleteVaccination` and before `getMedicalHistory`:

```dart
  // --- Contraindication engine ---
  //
  // Doctor-only: checks a proposed medication/vaccination against the
  // patient's logged allergies and active medications before it's saved,
  // and the admin-only CRUD for the hard-stop rule table behind it.

  Future<Map<String, dynamic>> checkContraindication(
    String token, {
    required String treatmentType,
    required String treatmentName,
    String? dosage,
  }) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/patients/token/$token/contraindication-check'),
      headers: _headers,
      body: jsonEncode({
        'treatmentType': treatmentType,
        'treatmentName': treatmentName,
        if (dosage != null && dosage.isNotEmpty) 'dosage': dosage,
      }),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not check for contraindications');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

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

  Future<List<Map<String, dynamic>>> getContraindicationRules() async {
    final res = await http.get(
      Uri.parse('$_baseUrl/contraindication-rules'),
      headers: _headers,
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not load contraindication rules');
    }
    return (jsonDecode(res.body) as List<dynamic>).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> createContraindicationRule({
    required String ruleType,
    required String triggerTerms,
    required String treatmentTerms,
    required String severity,
    required String reason,
  }) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/contraindication-rules'),
      headers: _headers,
      body: jsonEncode({
        'ruleType': ruleType,
        'triggerTerms': triggerTerms,
        'treatmentTerms': treatmentTerms,
        'severity': severity,
        'reason': reason,
      }),
    );
    if (res.statusCode != 201) {
      throw _errorFrom(res, 'Could not create the rule');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateContraindicationRule(
    int id, {
    required String ruleType,
    required String triggerTerms,
    required String treatmentTerms,
    required String severity,
    required String reason,
  }) async {
    final res = await http.put(
      Uri.parse('$_baseUrl/contraindication-rules/$id'),
      headers: _headers,
      body: jsonEncode({
        'ruleType': ruleType,
        'triggerTerms': triggerTerms,
        'treatmentTerms': treatmentTerms,
        'severity': severity,
        'reason': reason,
      }),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not update the rule');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<void> deleteContraindicationRule(int id) async {
    final res = await http.delete(
      Uri.parse('$_baseUrl/contraindication-rules/$id'),
      headers: _headers,
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not delete the rule');
    }
  }

```

Note: these use `_headers` (the doctor bearer token) directly rather than `_headersFor(token)` — this feature is doctor-only by design, never reachable from a patient's own session.

- [ ] **Step 2: Verify it compiles**

There is no Dart unit-test harness for `api.dart` in this project (it's exercised only by running the app; the backend it talks to is what `test/smoke.js` covers). Verify statically instead:

Run: `cd app && flutter analyze lib/api.dart`
Expected: no errors (warnings about existing code are fine; there should be none new from this change).

- [ ] **Step 3: Commit**

```bash
git add app/lib/api.dart
git commit -m "Add Flutter API client methods for the contraindication engine"
```

---

### Task 7: Wire the pre-check into the medication and vaccination screens

**Files:**
- Create: `app/lib/contraindication_dialogs.dart`
- Modify: `app/lib/screens/health_records/add_medication_screen.dart`
- Modify: `app/lib/screens/health_records/add_vaccination_screen.dart`

**Interfaces:**
- Consumes: `MedThruApi.instance.checkContraindication`/`.overrideContraindication`/`.isLoggedIn` (Task 6).
- Produces: `showHardStopOverrideDialog(context, {required hardStops}) -> Future<String?>` (the typed reason, or `null` if cancelled) and `showAiWarningDialog(context, {required aiFlag}) -> Future<bool>` (`true` = proceed), both exported from `app/lib/contraindication_dialogs.dart`.

- [ ] **Step 1: Create the shared dialog helpers**

Create `app/lib/contraindication_dialogs.dart`:

```dart
import 'package:flutter/material.dart';

/// Blocking dialog for a deterministic hard-stop match: lists every matched
/// rule's reason and requires the doctor to type a justification before the
/// proceed button enables. Returns the typed reason, or `null` if the
/// doctor cancelled instead.
Future<String?> showHardStopOverrideDialog(
  BuildContext context, {
  required List<Map<String, dynamic>> hardStops,
}) {
  final reasonController = TextEditingController();
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        icon: Icon(Icons.dangerous_outlined, color: Theme.of(context).colorScheme.error),
        title: const Text('Possible dangerous interaction'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final stop in hardStops) ...[
                Text(
                  '${(stop['triggerSource'] as String) == 'allergy' ? 'Allergy' : 'Current medication'}: '
                  '${stop['triggerLabel']}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(stop['reason'] as String),
                const SizedBox(height: 12),
              ],
              Text(
                "Type a reason to proceed anyway. This is recorded in the patient's audit log.",
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: reasonController,
                autofocus: true,
                maxLines: 2,
                onChanged: (_) => setDialogState(() {}),
                decoration: const InputDecoration(hintText: 'e.g. Desensitization already in place'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: reasonController.text.trim().isEmpty
                ? null
                : () => Navigator.pop(context, reasonController.text.trim()),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Proceed anyway'),
          ),
        ],
      ),
    ),
  );
}

/// Dismissible warning for a Gemini-only flag (no hard-stop rule matched).
/// Returns `true` if the doctor chose to proceed, `false` if they cancelled.
Future<bool> showAiWarningDialog(
  BuildContext context, {
  required Map<String, dynamic> aiFlag,
}) async {
  final proceed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.warning_amber_outlined),
      title: const Text('Possible interaction to review'),
      content: Text(
        aiFlag['reason'] as String? ??
            "This treatment may interact with the patient's allergies or medications.",
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Proceed anyway'),
        ),
      ],
    ),
  );
  return proceed ?? false;
}
```

- [ ] **Step 2: Wire the pre-check into `add_medication_screen.dart`**

In `app/lib/screens/health_records/add_medication_screen.dart`:

Add the import at the top, alongside the existing ones:

```dart
import '../../contraindication_dialogs.dart';
```

Add a new method right before `_save()`:

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
```

Replace the existing `_save()` method with:

```dart
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
        final proceed = await _runContraindicationCheck();
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

(Only the pre-check block at the top of the `try` is new; the rest is unchanged from the current file.)

- [ ] **Step 3: Wire the pre-check into `add_vaccination_screen.dart`**

In `app/lib/screens/health_records/add_vaccination_screen.dart`:

Add the import at the top, alongside the existing ones:

```dart
import '../../contraindication_dialogs.dart';
```

Add a new method right before `_save()`:

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
```

Replace the existing `_save()` method with:

```dart
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
        final proceed = await _runContraindicationCheck();
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

- [ ] **Step 4: Verify it compiles**

Run: `cd app && flutter analyze lib/contraindication_dialogs.dart lib/screens/health_records/add_medication_screen.dart lib/screens/health_records/add_vaccination_screen.dart`
Expected: no errors.

- [ ] **Step 5: Manual verification**

There's no widget-test harness covering these screens in this project (only the doctor dashboard has golden tests). Verify by running the app:

Run: `cd app && flutter run -d windows` (or your usual target)

- As a doctor, tap a patient's card, add a medication named `Amoxicillin` for a patient with a logged Penicillin allergy → the blocking dialog should appear; Save should stay disabled until you type an override reason; after confirming, the medication saves.
- Add a medication with an unrelated name (e.g. `Paracetamol`) → it should save immediately, no dialog.
- As a patient (not doctor-logged-in), add a medication yourself → no dialog should appear regardless of what you enter (the check is doctor-only).

- [ ] **Step 6: Commit**

```bash
git add app/lib/contraindication_dialogs.dart app/lib/screens/health_records/add_medication_screen.dart app/lib/screens/health_records/add_vaccination_screen.dart
git commit -m "Wire the contraindication pre-check into add medication/vaccination"
```

---

### Task 8: Admin rule management screen

**Files:**
- Create: `app/lib/screens/doctor/contraindication_rules_screen.dart`
- Modify: `app/lib/screens/doctor/doctor_settings_screen.dart`

**Interfaces:**
- Consumes: `MedThruApi.instance.getContraindicationRules`/`.createContraindicationRule`/`.updateContraindicationRule`/`.deleteContraindicationRule` (Task 6), `MedThruApi.instance.isAdmin` (existing).
- Produces: `ContraindicationRulesScreen` widget, navigable from Settings.

- [ ] **Step 1: Create the admin screen**

Create `app/lib/screens/doctor/contraindication_rules_screen.dart`:

```dart
import 'package:flutter/material.dart';
import '../../api.dart';
import '../../theme.dart';
import '../../widgets.dart';

/// Administrator-only screen for managing the hard-stop rule table behind
/// the triage contraindication engine (see contraindication.js on the
/// server). Reachable from Settings when `MedThruApi.instance.isAdmin`.
class ContraindicationRulesScreen extends StatefulWidget {
  const ContraindicationRulesScreen({super.key});

  @override
  State<ContraindicationRulesScreen> createState() => _ContraindicationRulesScreenState();
}

class _ContraindicationRulesScreenState extends State<ContraindicationRulesScreen> {
  late Future<List<Map<String, dynamic>>> _rules;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _rules = MedThruApi.instance.getContraindicationRules();
  }

  Future<void> _openForm({Map<String, dynamic>? existing}) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => _RuleFormDialog(existing: existing),
    );
    if (saved == true && mounted) setState(_load);
  }

  Future<void> _delete(Map<String, dynamic> rule) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this rule?'),
        content: Text('This removes the "${rule['reason']}" rule. This can\'t be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep it')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: MedThruTheme.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await MedThruApi.instance.deleteContraindicationRule(rule['id'] as int);
      if (mounted) setState(_load);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Contraindication rules'),
        actions: [
          IconButton(
            onPressed: () => _openForm(),
            icon: const Icon(Icons.add),
            tooltip: 'Add rule',
          ),
        ],
      ),
      body: BoundedBody(
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _rules,
          builder: (context, snap) {
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final rules = snap.data!;
            if (rules.isEmpty) {
              return const Center(child: Text('No rules yet.'));
            }
            return ListView.separated(
              padding: const EdgeInsets.all(20),
              itemCount: rules.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final rule = rules[i];
                return Card(
                  child: ListTile(
                    title: Text(rule['reason'] as String),
                    subtitle: Text(
                      '${rule['rule_type']} · triggers: ${rule['trigger_terms']} · '
                      'treatment: ${rule['treatment_terms']} · severity: ${rule['severity']}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: () => _openForm(existing: rule),
                          icon: const Icon(Icons.edit_outlined),
                        ),
                        IconButton(
                          onPressed: () => _delete(rule),
                          icon: Icon(Icons.delete_outline, color: scheme.error),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _RuleFormDialog extends StatefulWidget {
  const _RuleFormDialog({this.existing});
  final Map<String, dynamic>? existing;

  @override
  State<_RuleFormDialog> createState() => _RuleFormDialogState();
}

class _RuleFormDialogState extends State<_RuleFormDialog> {
  late String _ruleType = widget.existing?['rule_type'] as String? ?? 'allergy';
  late final _triggerTerms =
      TextEditingController(text: widget.existing?['trigger_terms'] as String? ?? '');
  late final _treatmentTerms =
      TextEditingController(text: widget.existing?['treatment_terms'] as String? ?? '');
  late String _severity = widget.existing?['severity'] as String? ?? 'high';
  late final _reason = TextEditingController(text: widget.existing?['reason'] as String? ?? '');
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void dispose() {
    _triggerTerms.dispose();
    _treatmentTerms.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_triggerTerms.text.trim().isEmpty ||
        _treatmentTerms.text.trim().isEmpty ||
        _reason.text.trim().isEmpty) {
      setState(() => _error = 'All fields except severity are required.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_isEdit) {
        await MedThruApi.instance.updateContraindicationRule(
          widget.existing!['id'] as int,
          ruleType: _ruleType,
          triggerTerms: _triggerTerms.text.trim(),
          treatmentTerms: _treatmentTerms.text.trim(),
          severity: _severity,
          reason: _reason.text.trim(),
        );
      } else {
        await MedThruApi.instance.createContraindicationRule(
          ruleType: _ruleType,
          triggerTerms: _triggerTerms.text.trim(),
          treatmentTerms: _treatmentTerms.text.trim(),
          severity: _severity,
          reason: _reason.text.trim(),
        );
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(_isEdit ? 'Edit rule' : 'Add rule'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'allergy', label: Text('Allergy')),
                ButtonSegment(value: 'medication', label: Text('Medication')),
              ],
              selected: {_ruleType},
              onSelectionChanged: (s) => setState(() => _ruleType = s.first),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _triggerTerms,
              decoration: InputDecoration(
                labelText: _ruleType == 'allergy' ? 'Allergen keywords' : 'Existing medication keywords',
                hintText: 'comma-separated, e.g. penicillin,amoxicillin',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _treatmentTerms,
              decoration: const InputDecoration(
                labelText: 'Proposed treatment keywords',
                hintText: 'comma-separated, e.g. amoxicillin,ampicillin',
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'high', label: Text('High')),
                ButtonSegment(value: 'moderate', label: Text('Moderate')),
              ],
              selected: {_severity},
              onSelectionChanged: (s) => setState(() => _severity = s.first),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _reason,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Reason shown to the doctor',
                alignLabelWithHint: true,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: scheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
    );
  }
}
```

- [ ] **Step 2: Add the Settings entry**

In `app/lib/screens/doctor/doctor_settings_screen.dart`:

Add the import at the top, alongside the existing ones:

```dart
import 'contraindication_rules_screen.dart';
```

In the `build()` method's `ListView`'s `children`, add this as the last item (right after the `OutlinedButton.icon` for "Change password"):

```dart
            if (_api.isAdmin) ...[
              const SizedBox(height: 32),
              Divider(color: scheme.outlineVariant),
              const SizedBox(height: 20),
              Text('Administration',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface)),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ContraindicationRulesScreen()),
                ),
                icon: const Icon(Icons.rule_outlined),
                label: const Text('Contraindication rules'),
              ),
            ],
```

- [ ] **Step 3: Verify it compiles**

Run: `cd app && flutter analyze lib/screens/doctor/contraindication_rules_screen.dart lib/screens/doctor/doctor_settings_screen.dart`
Expected: no errors.

- [ ] **Step 4: Manual verification**

Run: `cd app && flutter run -d windows` (or your usual target)

- Log in as a non-admin doctor → Settings should show no "Administration" section.
- Log in as an admin doctor (e.g. promote one via the same direct-DB approach used in the smoke test, or use an existing admin account) → Settings shows "Administration" → "Contraindication rules" → the list shows the 15 seeded rules → add, edit, and delete a test rule and confirm the list refreshes each time.

- [ ] **Step 5: Commit**

```bash
git add app/lib/screens/doctor/contraindication_rules_screen.dart app/lib/screens/doctor/doctor_settings_screen.dart
git commit -m "Add the admin contraindication rule management screen"
```

---

### Task 9: Final integration pass

**Files:**
- Modify: `package.json`

**Interfaces:**
- Consumes: all prior tasks.
- Produces: `npm test` runs every new test file alongside the existing ones.

- [ ] **Step 1: Update the test script**

In `package.json`, change:

```json
    "test": "node test/reschedule-scoring.js && node test/gemini.js && node test/smoke.js",
```

to:

```json
    "test": "node test/reschedule-scoring.js && node test/gemini.js && node test/contraindication.js && node test/contraindication-gemini.js && node test/smoke.js",
```

- [ ] **Step 2: Run the full suite**

Run: `npm test`
Expected: every unit test file and the full smoke test pass, ending with `All smoke checks passed.`

- [ ] **Step 3: Commit**

```bash
git add package.json
git commit -m "Run the contraindication unit tests as part of npm test"
```
