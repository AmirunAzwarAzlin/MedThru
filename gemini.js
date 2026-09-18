/// Thin wrapper around the Gemini API for turning an already-ranked list of
/// reschedule candidates (see `reschedule.js`) into a short rationale per
/// option. The ranking never comes from here — this module only captions the
/// top picks, and degrades to `null` (never throws) on any failure, so the
/// caller always has a templated fallback to use instead.
const { GoogleGenAI } = require('@google/genai');

const MODEL = 'gemini-2.5-flash';
const DEFAULT_TIMEOUT_MS = 4000;

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
    'Candidate slots, best first, with fit scores 0-100 (higher is better):',
    ...lines,
    'For each candidate, in the same order, write one short (under 20 words) ' +
      'rationale a patient would find reassuring, referencing only the day/time ' +
      'and urgency given above. Do not invent medical details.',
  ].join('\n');
}

/// Returns `[{ startsAt, rationale }]` in the same order as `candidates`, or
/// `null` if Gemini is unconfigured, unreachable, too slow, or responds with
/// something that doesn't parse. `genAI`/`timeoutMs` are injectable for
/// testing without a real API key or a real 4-second wait.
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

module.exports = { rationalizeCandidates, buildPrompt };
