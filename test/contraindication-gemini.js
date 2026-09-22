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
