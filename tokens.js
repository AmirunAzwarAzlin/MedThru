const crypto = require('node:crypto');

/// Card tokens are the secret written to the tag's NDEF data area — never the
/// tag's UID, which is broadcast to any reader, printed on some cards, and
/// clonable with a cheap copier.
///
/// 32 random bytes (256 bits) makes enumeration hopeless. We store only the
/// SHA-256 hash, so a stolen copy of the database does not hand over anyone's
/// card. No salt is needed: unlike passwords, these are already high-entropy,
/// and an unsalted hash lets us look a card up in one indexed query.

function generateCardToken() {
  return crypto.randomBytes(32).toString('base64url');
}

function hashCardToken(token) {
  return crypto.createHash('sha256').update(token, 'utf8').digest('hex');
}

/// A few trailing characters, safe to display, so staff can tell two cards
/// apart without the token itself ever appearing on screen.
function previewOf(token) {
  return token.slice(-4);
}

module.exports = { generateCardToken, hashCardToken, previewOf };
