// Unit tests for the Gemini wrapper. No real network call — a fake client is
// injected so these run offline and fast. The one thing worth proving here
// is that this module never throws: missing key, thrown error, timeout, and
// a malformed response all resolve to `null`.
'use strict';

const assert = require('node:assert');
const { rationalizeCandidates } = require('../gemini');

function check(condition, message) {
  assert.ok(condition, message);
  console.log(`ok - ${message}`);
}

const candidates = [
  { startsAt: '2026-09-25 10:00', patientFit: 80, clinicFit: 70, total: 76 },
];

async function main() {
  // No genAI client injected and no GEMINI_API_KEY in this test process's
  // environment (test/smoke.js doesn't set one) — the default client resolves
  // to null, so this must resolve to null without attempting a network call.
  delete process.env.GEMINI_API_KEY;
  const noKey = await rationalizeCandidates(
    { originalStartsAt: '2026-09-18 10:00', urgencyTag: 'routine', candidates }
  );
  check(noKey === null, 'no API key -> null, no network attempt');

  // A fake client that resolves with well-formed JSON.
  const goodClient = {
    models: {
      generateContent: async () => ({
        text: JSON.stringify({
          suggestions: [{ startsAt: '2026-09-25 10:00', rationale: 'Keeps your usual morning slot.' }],
        }),
      }),
    },
  };
  const good = await rationalizeCandidates(
    { originalStartsAt: '2026-09-18 10:00', urgencyTag: 'routine', candidates },
    { genAI: goodClient },
  );
  check(Array.isArray(good) && good.length === 1 && good[0].rationale.length > 0,
    'a well-formed response is returned as-is');

  // A fake client that throws.
  const throwingClient = {
    models: { generateContent: async () => { throw new Error('network down'); } },
  };
  const thrown = await rationalizeCandidates(
    { originalStartsAt: '2026-09-18 10:00', urgencyTag: 'routine', candidates },
    { genAI: throwingClient },
  );
  check(thrown === null, 'a thrown error resolves to null, not a rejected promise');

  // A fake client that never resolves — must hit the timeout, not hang.
  const hangingClient = {
    models: { generateContent: () => new Promise(() => {}) },
  };
  const start = Date.now();
  const timedOut = await rationalizeCandidates(
    { originalStartsAt: '2026-09-18 10:00', urgencyTag: 'routine', candidates },
    { genAI: hangingClient, timeoutMs: 200 },
  );
  check(timedOut === null, 'a hanging call times out to null');
  check(Date.now() - start < 1000, 'the timeout fires close to the configured delay, not the default');

  // A fake client that resolves with malformed JSON.
  const malformedClient = {
    models: { generateContent: async () => ({ text: '{"not": "the expected shape"}' }) },
  };
  const malformed = await rationalizeCandidates(
    { originalStartsAt: '2026-09-18 10:00', urgencyTag: 'routine', candidates },
    { genAI: malformedClient },
  );
  check(malformed === null, 'a malformed response resolves to null');

  console.log('All gemini tests passed.');
}

main();
