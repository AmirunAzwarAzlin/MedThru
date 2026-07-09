/// Minimal in-memory fixed-window rate limiter.
///
/// Enough to stop someone grinding through card tokens or brute-forcing a
/// doctor password against this prototype. A real deployment behind multiple
/// processes would need a shared store (Redis) instead of a Map.

function rateLimit({ windowMs, max, message }) {
  const hits = new Map(); // key -> { count, resetAt }

  // Drop expired buckets so the map cannot grow without bound.
  const sweep = setInterval(() => {
    const now = Date.now();
    for (const [key, bucket] of hits) {
      if (bucket.resetAt <= now) hits.delete(key);
    }
  }, windowMs).unref();

  const middleware = (req, res, next) => {
    const key = req.ip || req.socket.remoteAddress || 'unknown';
    const now = Date.now();
    let bucket = hits.get(key);

    if (!bucket || bucket.resetAt <= now) {
      bucket = { count: 0, resetAt: now + windowMs };
      hits.set(key, bucket);
    }

    bucket.count += 1;
    if (bucket.count > max) {
      const retryAfter = Math.ceil((bucket.resetAt - now) / 1000);
      res.set('Retry-After', String(retryAfter));
      return res.status(429).json({ error: message, retryAfter });
    }
    next();
  };

  // Exposed for tests, which need a clean slate between cases.
  middleware.reset = () => hits.clear();
  middleware._sweep = sweep;
  return middleware;
}

module.exports = { rateLimit };
