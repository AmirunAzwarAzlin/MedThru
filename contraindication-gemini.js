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
