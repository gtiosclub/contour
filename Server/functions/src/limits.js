"use strict";

// Every size, count and time limit the server enforces, in one place.

module.exports = Object.freeze({
  // /plan
  MAX_REQUEST_CHARS: 300,
  MAX_BUTTON_LABEL_CHARS: 60,
  MAX_PLAN_BODY_BYTES: 64 * 1024,
  // A plan longer than this is treated as a bad answer, not a real sequence.
  MAX_STEPS: 20,
  MAX_SAY_CHARS: 200,

  // /label
  MAX_IMAGE_BASE64_CHARS: 1_500_000,
  MAX_LABEL_BODY_BYTES: 1_600_000,
  MAX_OUTPUT_LABEL_CHARS: 40,

  // Both routes
  MAX_ITEMS: 120,
  MAX_ID_CHARS: 64,
  UPSTREAM_TIMEOUT_MS: 8000,

  // Caps on what the model may write. The timeout bounds it too; these stop a
  // runaway answer from being billed in full.
  MAX_COMPLETION_TOKENS: Object.freeze({ plan: 2000, label: 6000 }),

  // Per client IP, per function instance (see README, "Rate limit").
  RATE_LIMITS: Object.freeze({
    plan: Object.freeze({ max: 20, windowMs: 60_000 }),
    label: Object.freeze({ max: 6, windowMs: 60_000 }),
  }),
});
