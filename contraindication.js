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
