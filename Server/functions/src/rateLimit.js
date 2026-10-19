"use strict";

// Fixed-window request counter per key, in memory.
//
// It lives in one function instance. Cloud Functions runs up to maxInstances
// of them and each counts on its own, and a cold start forgets everything, so
// the real ceiling is max * maxInstances per window. Good enough to stop one
// client hammering the endpoint; the OpenAI budget is the hard cap.

function createRateLimiter({ max, windowMs, now = Date.now, maxKeys = 10_000 }) {
  const windows = new Map(); // key -> { start, count }

  function prune(t) {
    for (const [key, w] of windows) {
      if (t - w.start >= windowMs) windows.delete(key);
    }
    // Still full of live windows: drop the oldest so memory stays bounded.
    while (windows.size >= maxKeys) windows.delete(windows.keys().next().value);
  }

  return {
    // Counts one request for key. { allowed, retryAfterSeconds }
    hit(key) {
      const t = now();
      let w = windows.get(key);
      if (w && t - w.start >= windowMs) {
        windows.delete(key);
        w = undefined;
      }
      if (!w) {
        if (windows.size >= maxKeys) prune(t);
        w = { start: t, count: 0 };
        windows.set(key, w);
      }
      if (w.count >= max) {
        return { allowed: false, retryAfterSeconds: Math.max(1, Math.ceil((w.start + windowMs - t) / 1000)) };
      }
      w.count += 1;
      return { allowed: true, retryAfterSeconds: 0 };
    },
    get size() {
      return windows.size;
    },
  };
}

// The client's IP for rate limiting. On Cloud Functions (Cloud Run) Google's
// front end appends the address it saw to X-Forwarded-For, so the right-most
// entry is the one a client cannot forge; anything to its left is whatever the
// client sent. Falls back to the socket address (the emulator).
function clientIp(headers, remoteAddress) {
  const forwarded = headers && headers["x-forwarded-for"];
  const value = Array.isArray(forwarded) ? forwarded[forwarded.length - 1] : forwarded;
  if (typeof value === "string") {
    const parts = value.split(",").map((p) => p.trim()).filter(Boolean);
    if (parts.length > 0) return parts[parts.length - 1];
  }
  return remoteAddress || "unknown";
}

module.exports = { createRateLimiter, clientIp };
