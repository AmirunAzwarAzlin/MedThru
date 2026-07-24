// Writes a patient's card token onto a blank tag, as an NDEF URI record
// pointing at the emergency-view page — so any phone's stock NFC reader can
// open the card directly, not just MedThru's own reader.js bridge. Run this
// right after registering a patient (or reissuing a card) — the token is
// shown exactly once, so copy it straight from that dialog.
//
// The base URL must be reachable by whatever phone will tap this card later
// — not localhost. For the prototype that's your PC's Tailscale address
// (find it with `tailscale status`), e.g.:
//
//   node write-card.js <card-token> http://100.107.99.36:3000
//
// Falls back to MEDIC_EMERGENCY_BASE if the second argument is omitted.

const { NFC } = require('nfc-pcsc');
const { writeToken, readToken, TOKEN_LENGTH } = require('./tag-storage');

const token = process.argv[2];
const emergencyBaseUrl = process.argv[3] || process.env.MEDIC_EMERGENCY_BASE;

if (!token) {
  console.error('Usage: node write-card.js <card-token> <emergency-base-url>');
  process.exit(1);
}
if (Buffer.byteLength(token, 'ascii') !== TOKEN_LENGTH) {
  console.error(`Expected a ${TOKEN_LENGTH}-character card token, got ${token.length} characters.`);
  console.error('Paste the token exactly as shown when the card was issued.');
  process.exit(1);
}
if (!emergencyBaseUrl) {
  console.error('Missing emergency base URL: pass it as a second argument, or set MEDIC_EMERGENCY_BASE.');
  console.error('This must be an address the tapping phone can reach, e.g. your Tailscale IP:');
  console.error('  node write-card.js <card-token> http://100.107.99.36:3000');
  process.exit(1);
}

const nfc = new NFC();
let handled = false;

nfc.on('reader', reader => {
  console.log(`Reader connected: ${reader.reader.name}`);
  console.log('Tap the blank card now...');

  reader.on('card', async card => {
    if (handled) return;
    handled = true;

    console.log(`Card detected (UID ${card.uid}). Writing token...`);
    try {
      await writeToken(reader, token, { emergencyBaseUrl });
      const readBack = await readToken(reader);
      if (readBack === token) {
        console.log('Token written and verified — this card is ready.');
        process.exitCode = 0;
      } else {
        console.error('Wrote the token but the read-back did not match. Try a different card.');
        process.exitCode = 1;
      }
    } catch (err) {
      console.error(`Write failed: ${err.message}`);
      process.exitCode = 1;
    } finally {
      process.exit();
    }
  });

  reader.on('error', err => {
    console.error(`Reader error: ${err.message}`);
    process.exitCode = 1;
    process.exit();
  });
});

nfc.on('error', err => {
  console.error(`NFC error: ${err.message}`);
  process.exitCode = 1;
  process.exit();
});
