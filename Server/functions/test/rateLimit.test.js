"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const { createRateLimiter, clientIp } = require("../src/rateLimit");

function clock(start = 1_000_000) {
  let t = start;
  return { now: () => t, advance: (ms) => (t += ms) };
}

test("allows max requests per window, then blocks with a retry time", () => {
  const c = clock();
  const limiter = createRateLimiter({ max: 3, windowMs: 60_000, now: c.now });
  for (let i = 0; i < 3; i++) assert.equal(limiter.hit("ip").allowed, true);
  c.advance(15_000);
  assert.deepEqual(limiter.hit("ip"), { allowed: false, retryAfterSeconds: 45 });
});

test("a new window starts fresh", () => {
  const c = clock();
  const limiter = createRateLimiter({ max: 1, windowMs: 1000, now: c.now });
  assert.equal(limiter.hit("ip").allowed, true);
  assert.equal(limiter.hit("ip").allowed, false);
  c.advance(1000);
  assert.equal(limiter.hit("ip").allowed, true);
});

test("keys are counted separately", () => {
  const c = clock();
  const limiter = createRateLimiter({ max: 1, windowMs: 1000, now: c.now });
  assert.equal(limiter.hit("a").allowed, true);
  assert.equal(limiter.hit("b").allowed, true);
  assert.equal(limiter.hit("a").allowed, false);
});

test("memory stays bounded by maxKeys", () => {
  const c = clock();
  const limiter = createRateLimiter({ max: 1, windowMs: 1000, now: c.now, maxKeys: 5 });
  for (let i = 0; i < 5; i++) limiter.hit(`old-${i}`);
  c.advance(1000);
  limiter.hit("new");
  assert.equal(limiter.size, 1, "expired windows are pruned first");
  for (let i = 0; i < 50; i++) limiter.hit(`live-${i}`);
  assert.ok(limiter.size <= 5);
});

test("clientIp takes the right-most X-Forwarded-For entry", () => {
  assert.equal(clientIp({ "x-forwarded-for": "6.6.6.6, 203.0.113.9" }, "10.0.0.1"), "203.0.113.9");
  assert.equal(clientIp({ "x-forwarded-for": "203.0.113.9" }, "10.0.0.1"), "203.0.113.9");
  assert.equal(clientIp({ "x-forwarded-for": ["1.1.1.1", "2.2.2.2, 3.3.3.3 "] }), "3.3.3.3");
  assert.equal(clientIp({ "x-forwarded-for": " , " }, "10.0.0.1"), "10.0.0.1");
  assert.equal(clientIp({}, "127.0.0.1"), "127.0.0.1");
  assert.equal(clientIp(undefined, undefined), "unknown");
});
