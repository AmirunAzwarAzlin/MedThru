// Block-level read/write of a card token to/from an NTAG-family tag
// (4-byte blocks). Two layouts are understood when reading, so cards
// written before the NDEF format existed keep working:
//
//   - NDEF (current): a standard NFC Forum Type 2 Tag URI record — the
//     emergency-view URL with the token as its last path segment — wrapped
//     in an NDEF-message TLV starting at block 4. This is what makes the
//     card openable by a stock phone's NFC + browser with no MedThru app
//     involved at all, which raw bytes never could be.
//   - Legacy raw (older cards): the token's ASCII bytes directly at block
//     4, zero-padded to the next block boundary, no NDEF framing. Only
//     MedThru's own reader.js ever understood this format.
//
// Blocks 0-3 are the tag's UID/lock/capability-container area and are never
// touched by either layout — the factory-set capability container already
// marks block 4 onward as the NDEF area.

const BLOCK_SIZE = 4;
const START_BLOCK = 4;

// crypto.randomBytes(32).toString('base64url') is always exactly 43
// characters — base64url of a fixed-length input has no padding variance.
const TOKEN_LENGTH = 43;
const LEGACY_PADDED_LENGTH = Math.ceil((TOKEN_LENGTH + 1) / BLOCK_SIZE) * BLOCK_SIZE;

// Generous enough for "http://" + a LAN/Tailscale host:port + "/emergency/"
// + the 43-character token, with room to spare — verified against real
// NTAG215/216 stock (400+ usable bytes from block 4), comfortably short of
// the ~900 bytes where reads started failing.
const NDEF_READ_LENGTH = 240;

// NFC Forum "URI Record Type Definition" abbreviation codes: the leading
// payload byte that lets common prefixes be omitted instead of spelled out.
// Only the prefixes MedThru could plausibly emit are listed.
const URI_ABBREVIATIONS = [
  '', 'http://www.', 'https://www.', 'http://', 'https://', 'tel:', 'mailto:',
];

function abbreviateUri(uri) {
  for (let code = URI_ABBREVIATIONS.length - 1; code >= 1; code--) {
    const prefix = URI_ABBREVIATIONS[code];
    if (uri.startsWith(prefix)) return { code, rest: uri.slice(prefix.length) };
  }
  return { code: 0, rest: uri };
}

function expandUri(code, rest) {
  return (URI_ABBREVIATIONS[code] || '') + rest;
}

/// Wraps a URI in a single short well-known-type NDEF "U" record, itself
/// wrapped in the TLV that marks it as the tag's NDEF message.
function buildUriRecordTlv(uri) {
  const { code, rest } = abbreviateUri(uri);
  const payload = Buffer.concat([Buffer.from([code]), Buffer.from(rest, 'utf8')]);
  if (payload.length > 255) {
    throw new Error(`URI too long for a short NDEF record (${payload.length} bytes)`);
  }
  const record = Buffer.concat([
    Buffer.from([0xd1]), // MB=1 ME=1 SR=1 TNF=0x01 (well-known type)
    Buffer.from([0x01]), // type length: 1 ('U')
    Buffer.from([payload.length]), // payload length (short record: 1 byte)
    Buffer.from('U', 'ascii'),
    payload,
  ]);
  if (record.length > 255) {
    throw new Error(`URI too long for a single-byte NDEF TLV length (${record.length} bytes)`);
  }
  return Buffer.concat([Buffer.from([0x03, record.length]), record, Buffer.from([0xfe])]);
}

/// Inverse of buildUriRecordTlv. Returns null if `data` doesn't start with
/// an NDEF-message TLV or the message isn't a single well-known "U" record
/// — either way, the caller falls back to the legacy raw layout.
function parseUriRecordTlv(data) {
  if (data[0] !== 0x03) return null;
  const len = data[1];
  const record = data.subarray(2, 2 + len);
  if (record.length < 4 || record[3] !== 0x55 /* 'U' */) return null;
  const typeLength = record[1];
  const payloadLength = record[2];
  const payload = record.subarray(3 + typeLength, 3 + typeLength + payloadLength);
  if (payload.length === 0) return null;
  return expandUri(payload[0], payload.subarray(1).toString('utf8'));
}

/// Writes the emergency-view URL (with the token as its final path segment)
/// as a standard NDEF URI record, so any phone's stock NFC reader can open
/// it directly — see the module comment for why this replaces the old
/// raw-token layout for newly written cards.
async function writeToken(reader, token, { emergencyBaseUrl } = {}) {
  if (Buffer.byteLength(token, 'ascii') !== TOKEN_LENGTH) {
    throw new Error(`Expected a ${TOKEN_LENGTH}-character card token, got ${token.length}`);
  }
  if (!emergencyBaseUrl) {
    throw new Error('emergencyBaseUrl is required to write a card (e.g. http://100.x.x.x:3000)');
  }
  const uri = `${emergencyBaseUrl.replace(/\/$/, '')}/emergency/${token}`;
  const tlv = buildUriRecordTlv(uri);
  const padded = Buffer.alloc(Math.ceil(tlv.length / BLOCK_SIZE) * BLOCK_SIZE, 0);
  tlv.copy(padded);
  await reader.write(START_BLOCK, padded, BLOCK_SIZE);
}

/// Reads back whichever layout is on the card (NDEF URI or legacy raw) and
/// returns just the token, so callers (reader.js) don't need to know or
/// care which format wrote it.
async function readToken(reader) {
  const data = await reader.read(START_BLOCK, NDEF_READ_LENGTH, BLOCK_SIZE);

  const uri = parseUriRecordTlv(data);
  if (uri) return uri.split('/').pop() || null;

  // Legacy raw layout: the token's ASCII bytes, zero-terminated. Only look
  // at the prefix a legacy write would have used, since NDEF_READ_LENGTH is
  // much larger than that layout's padding.
  const legacy = data.subarray(0, LEGACY_PADDED_LENGTH);
  const terminator = legacy.indexOf(0);
  const raw = terminator === -1 ? legacy : legacy.subarray(0, terminator);
  const text = raw.toString('ascii');
  return text || null;
}

module.exports = { writeToken, readToken, TOKEN_LENGTH };
