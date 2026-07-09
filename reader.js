const { NFC } = require('nfc-pcsc');
const { lookupPatientByToken } = require('./lookup');

const nfc = new NFC();

nfc.on('reader', reader => {
  console.log(`Reader connected: ${reader.reader.name}`);

  reader.on('card', async card => {
    console.log(`Card detected, UID: ${card.uid}`);
    await lookupPatientByToken(card.uid);
  });

  reader.on('card.off', card => {
    console.log(`Card removed: ${card.uid}`);
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
