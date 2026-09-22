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
