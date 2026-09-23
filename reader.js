const { NFC } = require('nfc-pcsc');
const { lookupPatientByToken } = require('./lookup');
const { readToken } = require('./tag-storage');

const API_BASE = process.env.MEDTHRU_API || 'http://localhost:3000/api';

/// Pushes the tap to any listening app instance over the taps/stream SSE
/// channel, so the app can react the moment a card is presented instead of
/// someone typing the token in by hand. Best-effort: a broadcast failure
/// (e.g. the server isn't running) shouldn't stop the console lookup below.
async function broadcastTap(token) {
  try {
    await fetch(`${API_BASE}/taps`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token }),
    });
  } catch (err) {
    console.error(`Could not broadcast tap to the app: ${err.message}`);
  }
}

const nfc = new NFC();

nfc.on('reader', reader => {
  console.log(`Reader connected: ${reader.reader.name}`);

  reader.on('card', async card => {
    // The hardware UID (card.uid) is never the credential — it's broadcast
    // to any reader and clonable with a cheap copier. The real token lives
    // in the tag's data blocks, written there by write-card.js.
    console.log(`Card detected (UID ${card.uid}) — reading stored token...`);
    let token;
    try {
      token = await readToken(reader);
    } catch (err) {
      console.error(`Could not read this card: ${err.message}`);
      return;
    }
    if (!token) {
      console.log('This card has no MedThru token written to it yet.');
      return;
    }
    await lookupPatientByToken(token);
  });

  reader.on('card.off', card => {
    console.log(`Card removed (UID ${card.uid})`);
  });

  reader.on('error', err => {
    console.error(`Reader error: ${err.message}`);
  });

  reader.on('end', () => {
    console.log(`Reader disconnected: ${reader.reader.name}`);
  });
});

nfc.on('error', err => {
  console.error(`NFC error: ${err.message}`);
});

console.log('Waiting for NFC reader... plug in the ACR122U and tap a card.');
