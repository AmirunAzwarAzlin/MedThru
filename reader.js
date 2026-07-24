const net = require('net');
const path = require('path');
const { exec, spawn } = require('child_process');
const { NFC } = require('nfc-pcsc');
const { lookupPatientByToken } = require('./lookup');
const { readToken } = require('./tag-storage');

const API_BASE = process.env.MEDTHRU_API || 'http://localhost:3000/api';
const SERVER_PORT = 3000;
const SERVER_JS = path.join(__dirname, 'server.js');
const APP_EXE = path.join(
  __dirname,
  'app',
  'build',
  'windows',
  'x64',
  'runner',
  'Debug',
  'medthru_app.exe',
);

function isAppRunning() {
  return new Promise(resolve => {
    exec('tasklist /FI "IMAGENAME eq medthru_app.exe" /NH', (err, stdout) => {
      resolve(!err && stdout.toLowerCase().includes('medthru_app.exe'));
    });
  });
}

function isPortOpen(port) {
  return new Promise(resolve => {
    const socket = net.createConnection({ port, host: '127.0.0.1' });
    socket.once('connect', () => {
      socket.destroy();
      resolve(true);
    });
    socket.once('error', () => resolve(false));
    socket.setTimeout(500, () => {
      socket.destroy();
      resolve(false);
    });
  });
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

/// A tap should work from a completely cold machine — reader running,
/// nothing else. If the backend isn't listening, start it ourselves and
/// wait for it to come up before doing anything that depends on it (the
/// app launch below still works without this, but the patient lookup
/// inside the app needs the server to actually find the record).
async function ensureServerRunning() {
  if (await isPortOpen(SERVER_PORT)) return;
  try {
    spawn(process.execPath, [SERVER_JS], {
      cwd: __dirname,
      detached: true,
      stdio: 'ignore',
    }).unref();
    console.log('Backend was not running — starting it...');
  } catch (err) {
    console.error(`Could not start the backend: ${err.message}`);
    return;
  }
  for (let i = 0; i < 20; i++) {
    if (await isPortOpen(SERVER_PORT)) return;
    await sleep(250);
  }
  console.error('Backend did not come up in time — continuing anyway.');
}

/// If the app isn't already open, launch it straight into this patient's
/// record instead of leaving the tap to go unnoticed. If it IS already
/// running, do nothing here — the SSE broadcast above is what it reacts to.
async function ensureAppOpen(token) {
  if (await isAppRunning()) return;
  try {
    spawn(APP_EXE, [`--token=${token}`], {
      detached: true,
      stdio: 'ignore',
    }).unref();
    console.log('MedThru app was not running — launched it with this card.');
  } catch (err) {
    console.error(`Could not launch the app: ${err.message}`);
  }
}

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
    // This runs as an unattended background service now that a tap can
    // launch the app — one bad tap (server down, read glitch, whatever)
    // must never take the whole bridge down, so the entire handler is
    // wrapped rather than trusting each step to fail safely on its own.
    try {
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
      console.log(`Token: ${token}`);
      await ensureServerRunning();
      await broadcastTap(token);
      await ensureAppOpen(token);
      await lookupPatientByToken(token);
    } catch (err) {
      console.error(`Unexpected error handling this tap: ${err.message}`);
    }
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
