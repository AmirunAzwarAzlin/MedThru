/// Thin wrapper around the Gemini API for ordering and captioning a fixed set
/// of reschedule candidates (see `reschedule.js`). Gemini may reorder the set
/// by suitability but never changes its membership — the caller (server.js)
/// verifies the returned slots are exactly the same set before trusting the
/// order, and always has both a deterministic order and a templated
/// rationale to fall back to. Degrades to `null` (never throws) on any
/// failure.
const { GoogleGenAI } = require('@google/genai');

const MODEL = 'gemini-flash-lite-latest';
// Measured real-world latency for a 5-candidate structured request ranges
// from ~2s to over 20s (free-tier throttling under load), so 4s made the
// fallback fire on almost every real request. 10s trades a longer spinner
// for actually showing the AI rationale most of the time.
const DEFAULT_TIMEOUT_MS = 10000;

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
    suggestions: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          startsAt: { type: 'string' },
          rationale: { type: 'string' },
        },
        required: ['startsAt', 'rationale'],
      },
    },
  },
  required: ['suggestions'],
};

function buildPrompt({ originalStartsAt, urgencyTag, candidates }) {
  const lines = candidates.map((c) =>
    `- ${c.startsAt} (patientFit=${c.patientFit.toFixed(0)}, clinicFit=${c.clinicFit.toFixed(0)})`
  );
  return [
    `A patient's appointment originally at ${originalStartsAt} needs to move. Urgency: ${urgencyTag}.`,
    'Candidate slots, with fit scores 0-100 (higher is better), listed here in no particular order:',
    ...lines,
    'Decide the best order to present these in, from most to least suitable ' +
      'for the patient — weigh the fit scores given above, but use your own ' +
      'judgement rather than just sorting by a single number. Return every ' +
      'one of the candidate slots exactly once, in your chosen order, each ' +
      'with a short (under 20 words) rationale a patient would find ' +
      'reassuring, referencing only the day/time and urgency given above. ' +
      'Do not invent medical details, and do not add or omit any slot.',
  ].join('\n');
}

/// Returns `[{ startsAt, rationale }]` in the order Gemini judges best, or
/// `null` if Gemini is unconfigured, unreachable, too slow, or responds with
/// something that doesn't parse.
///
/// The response is expected to be a reordering of the same candidate set, but
/// nothing *enforces* that Gemini didn't drop, duplicate, or invent a slot —
/// the caller must verify the returned set exactly matches the candidates
/// before trusting the order, and match rationale back by `startsAt` rather
/// than by position regardless.
///
/// `genAI`/`timeoutMs` are injectable for testing without a real API key or a
/// real multi-second wait.
async function rationalizeCandidates(
  { originalStartsAt, urgencyTag, candidates },
  { genAI = defaultClient(), timeoutMs = DEFAULT_TIMEOUT_MS } = {},
) {
  if (!genAI || candidates.length === 0) return null;

  // Track the timer so it can be cleared once the race settles — an
  // uncleared setTimeout keeps the event loop (and the caller's process)
  // alive until it fires, even after the real call has already won the race.
  let timer;
  try {
    const response = await Promise.race([
      genAI.models.generateContent({
        model: MODEL,
        contents: buildPrompt({ originalStartsAt, urgencyTag, candidates }),
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
    if (!Array.isArray(parsed.suggestions) || parsed.suggestions.length === 0) {
      return null;
    }
    return parsed.suggestions;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/// Decides the final slot order for `ranked` (the deterministic candidates
/// from `reschedule.js`, each with a `startsAt`), given whatever
/// `rationalizeCandidates` returned (or `null`).
///
/// Trusts Gemini's order only if it's an exact permutation of `ranked`'s
/// `startsAt` values — same length, no duplicates, no hallucinated or
/// dropped slot. Anything else, including no response at all, keeps
/// `ranked`'s own order. Pure and synchronous: takes no dependency on
/// Gemini being configured, so it's trivial to unit test with a hand-built
/// `aiSuggestions` array.
function orderedStartsAts(ranked, aiSuggestions) {
  const rankedStartsAts = new Set(ranked.map((r) => r.startsAt));
  const aiOrder = (aiSuggestions ?? []).map((s) => s.startsAt);
  const isValidReorder =
    aiOrder.length === ranked.length &&
    new Set(aiOrder).size === aiOrder.length &&
    aiOrder.every((startsAt) => rankedStartsAts.has(startsAt));

  return isValidReorder ? aiOrder : ranked.map((r) => r.startsAt);
}

module.exports = { rationalizeCandidates, buildPrompt, orderedStartsAts };
