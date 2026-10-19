"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const L = require("../src/limits");
const { createHandler, appCheckBypassEnabled, routeOf } = require("../src/handler");
const { CANNOT_PLAN, NO_BUTTONS } = require("../src/repair");

const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0xff, 0xd9]).toString("base64");
const TOKEN = "app-check-token";
const IP = "203.0.113.7";

const PLAN_BODY = {
  request: "cook for a minute and a half",
  buttons: [
    { id: "5C1F0D6E-0001", label: "1" },
    { id: "5C1F0D6E-0003", label: "3" },
    { id: "5C1F0D6E-0000", label: "0" },
    { id: "5C1F0D6E-STRT", label: "Start" },
  ],
};
const LABEL_BODY = {
  image: JPEG,
  boxes: [
    { id: "b1", x: 0.1, y: 0.2, w: 0.1, h: 0.05 },
    { id: "b7", x: 0.5, y: 0.8, w: 0.2, h: 0.05 },
  ],
};

const completion = (value) =>
  new Response(
    JSON.stringify({
      choices: [{ finish_reason: "stop", message: { content: JSON.stringify(value), refusal: null } }],
      usage: { prompt_tokens: 300, completion_tokens: 20 },
    }),
    { status: 200 }
  );

// A handler with recording fakes for everything outside the process.
function setup({ answer, fetch, verify, bypass = false, config, timeoutMs, limiters } = {}) {
  const calls = { fetch: [], verify: [], logs: [] };
  const handle = createHandler({
    fetch: async (url, init) => {
      calls.fetch.push({ url, body: JSON.parse(init.body) });
      if (fetch) return fetch(url, init);
      return completion(answer);
    },
    verifyAppCheck: async (token) => {
      calls.verify.push(token);
      if (verify) return verify(token);
      if (token !== TOKEN) throw new Error("invalid token");
      return { appId: "1:123:ios:abc" };
    },
    appCheckBypass: bypass,
    getConfig: () => config || { apiKey: "test-key", model: "test-model", reasoningEffort: "" },
    log: (entry) => calls.logs.push(entry),
    ...(timeoutMs ? { timeoutMs } : {}),
    ...(limiters ? { limiters } : {}),
  });
  return { handle, calls };
}

function request(path, body, { method = "POST", token = TOKEN, headers = {}, bodyBytes } = {}) {
  const raw = body === undefined ? "" : JSON.stringify(body);
  return {
    method,
    path,
    headers: { "x-forwarded-for": IP, ...(token ? { "x-firebase-appcheck": token } : {}), ...headers },
    body,
    bodyBytes: bodyBytes === undefined ? Buffer.byteLength(raw) : bodyBytes,
    remoteAddress: "10.0.0.1",
  };
}

test("plan: the contract example end to end", async () => {
  const { handle, calls } = setup({ answer: { steps: [1, 2, 3, 4], say: "Press 1, 3, 0, then Start." } });
  const res = await handle(request("/plan", PLAN_BODY));

  assert.equal(res.status, 200);
  assert.deepEqual(res.body, {
    steps: ["5C1F0D6E-0001", "5C1F0D6E-0003", "5C1F0D6E-0000", "5C1F0D6E-STRT"],
    say: "Press 1, 3, 0, then Start.",
  });
  assert.equal(res.headers["Cache-Control"], "no-store");
  assert.deepEqual(calls.verify, [TOKEN]);
  assert.equal(calls.fetch.length, 1);
  const sent = calls.fetch[0].body;
  assert.equal(sent.model, "test-model");
  assert.equal(sent.response_format.json_schema.name, "plan");
  assert.equal(sent.max_completion_tokens, L.MAX_COMPLETION_TOKENS.plan);
});

test("label: the contract example end to end", async () => {
  const { handle, calls } = setup({
    answer: {
      boxes: [
        { n: 1, label: "Popcorn", isButton: true },
        { n: 2, label: "Start", isButton: true },
        { n: 9, label: "Invented", isButton: true },
      ],
      start: 2,
    },
  });
  const res = await handle(request("/label", LABEL_BODY));

  assert.equal(res.status, 200);
  assert.deepEqual(res.body, {
    boxes: [
      { id: "b1", label: "Popcorn", isButton: true },
      { id: "b7", label: "Start", isButton: true },
    ],
    start: "b7",
  });
  const content = calls.fetch[0].body.messages[1].content;
  assert.equal(content[1].image_url.url, `data:image/jpeg;base64,${JPEG}`);
  assert.equal(calls.fetch[0].body.response_format.json_schema.name, "label");
});

test("plan: a step the model invented gives no steps, never a partial plan", async () => {
  const { handle } = setup({ answer: { steps: [1, 7, 4], say: "Press 1, 7, Start." } });
  const res = await handle(request("/plan", PLAN_BODY));
  assert.equal(res.status, 200);
  assert.deepEqual(res.body, { steps: [], say: CANNOT_PLAN });
});

test("plan: when the model can't do it, its reason is spoken with 200", async () => {
  const { handle } = setup({ answer: { steps: [], say: "This microwave has no defrost button." } });
  const res = await handle(request("/plan", PLAN_BODY));
  assert.equal(res.status, 200);
  assert.deepEqual(res.body, { steps: [], say: "This microwave has no defrost button." });
});

test("App Check: a missing or invalid token is 401 and never reaches the model", async () => {
  const { handle, calls } = setup({ answer: { steps: [1], say: "" } });

  const missing = await handle(request("/plan", PLAN_BODY, { token: null }));
  assert.equal(missing.status, 401);
  assert.deepEqual(missing.body, { steps: [], say: "Sorry, Contour couldn't verify this app.", error: "unauthorized" });

  const invalid = await handle(request("/label", LABEL_BODY, { token: "forged" }));
  assert.equal(invalid.status, 401);
  assert.deepEqual(invalid.body.boxes, []);
  assert.equal(invalid.body.start, null);

  assert.deepEqual(calls.verify, ["forged"]);
  assert.equal(calls.fetch.length, 0);
});

test("App Check: the bypass skips verification", async () => {
  const { handle, calls } = setup({ bypass: true, answer: { steps: [4], say: "" } });
  const res = await handle(request("/plan", PLAN_BODY, { token: null }));
  assert.equal(res.status, 200);
  assert.deepEqual(res.body, { steps: ["5C1F0D6E-STRT"], say: "Press Start." });
  assert.equal(calls.verify.length, 0);
  assert.equal(calls.logs[0].appCheck, "bypassed");
});

test("App Check: the bypass only turns on inside the emulator", () => {
  assert.equal(appCheckBypassEnabled({ FUNCTIONS_EMULATOR: "true", APPCHECK_BYPASS: "true" }), true);
  assert.equal(appCheckBypassEnabled({ APPCHECK_BYPASS: "true" }), false);
  assert.equal(appCheckBypassEnabled({ FUNCTIONS_EMULATOR: "true" }), false);
  assert.equal(appCheckBypassEnabled({ FUNCTIONS_EMULATOR: "true", APPCHECK_BYPASS: "1" }), false);
  assert.equal(appCheckBypassEnabled({}), false);
});

test("routing: POST only, unknown paths 404, prefixes and trailing slashes ok", async () => {
  assert.equal(routeOf("/plan"), "plan");
  assert.equal(routeOf("/plan/"), "plan");
  assert.equal(routeOf("/api/label"), "label");
  assert.equal(routeOf("/"), null);
  assert.equal(routeOf("/constructor"), null);
  assert.equal(routeOf(undefined), null);

  const { handle, calls } = setup({ answer: { steps: [], say: "" } });
  const get = await handle(request("/plan", undefined, { method: "GET" }));
  assert.equal(get.status, 405);
  assert.equal(get.headers.Allow, "POST");
  const missing = await handle(request("/nope", PLAN_BODY));
  assert.equal(missing.status, 404);
  assert.equal(missing.body.error, "not_found");
  assert.equal(typeof missing.body.say, "string");
  assert.equal(calls.verify.length, 0);
});

test("size: an oversized body is 413 before App Check", async () => {
  const { handle, calls } = setup({});
  const plan = await handle(request("/plan", PLAN_BODY, { bodyBytes: L.MAX_PLAN_BODY_BYTES + 1 }));
  assert.equal(plan.status, 413);
  assert.deepEqual(plan.body.steps, []);
  const label = await handle(request("/label", LABEL_BODY, { bodyBytes: L.MAX_LABEL_BODY_BYTES + 1 }));
  assert.equal(label.status, 413);
  assert.equal(calls.verify.length, 0);
});

test("size: an oversized image inside an allowed body is still 413", async () => {
  const { handle, calls } = setup({});
  const image = "/9j/" + "A".repeat(L.MAX_IMAGE_BASE64_CHARS);
  const res = await handle(request("/label", { image, boxes: LABEL_BODY.boxes }));
  assert.equal(res.status, 413);
  assert.equal(res.body.say, "That photo is too large. Please try again.");
  assert.equal(calls.fetch.length, 0);
});

test("rate limit: per IP and per route, with Retry-After", async () => {
  const { handle, calls } = setup({ answer: { steps: [], say: "No." } });
  for (let i = 0; i < L.RATE_LIMITS.plan.max; i++) {
    assert.equal((await handle(request("/plan", PLAN_BODY))).status, 200);
  }
  const limited = await handle(request("/plan", PLAN_BODY));
  assert.equal(limited.status, 429);
  assert.equal(limited.body.error, "rate_limited");
  assert.ok(Number(limited.headers["Retry-After"]) >= 1);

  // Another IP, and the other route, are unaffected.
  const other = await handle(request("/plan", PLAN_BODY, { headers: { "x-forwarded-for": "198.51.100.1" } }));
  assert.equal(other.status, 200);
  const label = await handle(request("/label", { image: JPEG, boxes: [] }));
  assert.equal(label.status, 200);

  assert.equal(calls.fetch.length, L.RATE_LIMITS.plan.max + 1);
});

test("validation: 400 with a developer detail and the success shape", async () => {
  const { handle, calls } = setup({});
  const res = await handle(request("/plan", { request: "start", buttons: [{ id: "a" }, { id: "a" }] }));
  assert.equal(res.status, 400);
  assert.equal(res.body.error, "invalid_request");
  assert.deepEqual(res.body.steps, []);
  assert.match(res.body.detail, /duplicate/);

  const long = await handle(request("/plan", { request: "a".repeat(301), buttons: PLAN_BODY.buttons }));
  assert.equal(long.status, 400);
  assert.equal(long.body.say, "That was a bit long. Please say it more briefly.");

  const label = await handle(request("/label", { image: `data:image/jpeg;base64,${JPEG}`, boxes: [] }));
  assert.equal(label.status, 400);
  assert.equal(label.body.start, null);
  assert.equal(calls.fetch.length, 0);
});

test("nothing to work with: answered without calling the model", async () => {
  const { handle, calls } = setup({});
  const plan = await handle(request("/plan", { request: "start", buttons: [] }));
  assert.equal(plan.status, 200);
  assert.deepEqual(plan.body, { steps: [], say: NO_BUTTONS });
  const label = await handle(request("/label", { image: JPEG, boxes: [] }));
  assert.equal(label.status, 200);
  assert.deepEqual(label.body, { boxes: [], start: null });
  assert.equal(calls.fetch.length, 0);
});

test("config: no model or key is 500 and never calls out", async () => {
  for (const config of [{ apiKey: "k", model: "" }, { apiKey: "", model: "m" }]) {
    const { handle, calls } = setup({ config });
    const res = await handle(request("/plan", PLAN_BODY));
    assert.equal(res.status, 500);
    assert.equal(res.body.error, "misconfigured");
    assert.equal(calls.fetch.length, 0);
  }
  const throws = createHandler({
    fetch: async () => assert.fail("must not call"),
    verifyAppCheck: async () => ({}),
    getConfig: () => {
      throw new Error("secret not available");
    },
  });
  assert.equal((await throws(request("/plan", PLAN_BODY))).status, 500);
});

test("upstream: timeout is 504, errors are 502, each with a spoken sentence", async () => {
  const hang = (_url, init) =>
    new Promise((_resolve, reject) => init.signal.addEventListener("abort", () => reject(init.signal.reason)));
  const slow = setup({ fetch: hang, timeoutMs: 20 });
  const timedOut = await slow.handle(request("/label", LABEL_BODY));
  assert.equal(timedOut.status, 504);
  assert.deepEqual(timedOut.body, { boxes: [], start: null, say: "That took too long. Please try again.", error: "upstream_timeout" });
  assert.equal(slow.calls.logs[0].upstream, "timeout");

  const down = setup({ fetch: async () => new Response("{}", { status: 503 }) });
  const failed = await down.handle(request("/plan", PLAN_BODY));
  assert.equal(failed.status, 502);
  assert.deepEqual(failed.body.steps, []);
  assert.equal(failed.body.error, "upstream_error");
  assert.equal(down.calls.logs[0].upstreamStatus, 503);
});

test("upstream: a refusal is a 200 'can't do that' for plan and a 502 for label", async () => {
  const refuse = async () =>
    new Response(JSON.stringify({ choices: [{ finish_reason: "stop", message: { content: null, refusal: "no" } }] }));
  const { handle } = setup({ fetch: refuse });
  const plan = await handle(request("/plan", PLAN_BODY));
  assert.equal(plan.status, 200);
  assert.deepEqual(plan.body, { steps: [], say: "Sorry, I can't help with that." });
  const label = await handle(request("/label", LABEL_BODY));
  assert.equal(label.status, 502);
});

test("an unexpected error is a 500 with a spoken sentence, not a throw", async () => {
  const broken = { hit: () => {
    throw new Error("boom");
  } };
  const { handle, calls } = setup({ limiters: { plan: broken, label: broken } });
  const res = await handle(request("/plan", PLAN_BODY));
  assert.equal(res.status, 500);
  assert.equal(res.body.error, "internal");
  assert.equal(calls.logs[0].error, "Error");
});

test("logs: one entry per request with sizes, timings and outcomes only", async () => {
  const { handle, calls } = setup({ answer: { boxes: [{ n: 1, label: "Popcorn", isButton: true }], start: 1 } });
  await handle(request("/label", LABEL_BODY));
  const plan = setup({ answer: { steps: [1, 2, 3, 4], say: "" } });
  await plan.handle(request("/plan", PLAN_BODY));

  const [labelLog] = calls.logs;
  const [planLog] = plan.calls.logs;
  assert.equal(calls.logs.length, 1);
  assert.equal(plan.calls.logs.length, 1);

  assert.equal(labelLog.route, "label");
  assert.equal(labelLog.status, 200);
  assert.equal(labelLog.outcome, "ok");
  assert.equal(labelLog.boxes, 2);
  assert.equal(labelLog.labeled, 1);
  assert.equal(labelLog.hasStart, true);
  assert.equal(typeof labelLog.imageBytes, "number");
  assert.equal(typeof labelLog.upstreamMs, "number");
  assert.equal(typeof labelLog.totalMs, "number");
  assert.equal(labelLog.promptTokens, 300);

  assert.equal(planLog.buttons, 4);
  assert.equal(planLog.steps, 4);
  assert.equal(planLog.requestChars, PLAN_BODY.request.length);

  const text = JSON.stringify([labelLog, planLog]);
  // Labels are checked quoted so the key "hasStart" doesn't count as a match.
  for (const secret of [JPEG, PLAN_BODY.request, "minute", '"Popcorn"', '"Start"', "5C1F0D6E", "b7", IP, TOKEN, "test-key"]) {
    assert.ok(!text.includes(secret), `log must not contain ${secret}`);
  }
});
