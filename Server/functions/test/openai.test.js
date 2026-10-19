"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const { completeJson, UpstreamError, CHAT_COMPLETIONS_URL } = require("../src/openai");

const schema = { type: "object", properties: { a: { type: "integer" } }, required: ["a"], additionalProperties: false };

const completion = (content, extra = {}) => ({
  choices: [{ index: 0, finish_reason: "stop", message: { role: "assistant", content, refusal: null }, ...extra }],
  usage: { prompt_tokens: 120, completion_tokens: 9 },
});

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

function call(fetch, overrides = {}) {
  return completeJson({
    fetch,
    apiKey: "test-key",
    model: "test-model",
    messages: [{ role: "user", content: "hi" }],
    schemaName: "plan",
    schema,
    maxCompletionTokens: 50,
    timeoutMs: 1000,
    ...overrides,
  });
}

async function rejectsWith(promise, kind, httpStatus) {
  await assert.rejects(promise, (err) => {
    assert.ok(err instanceof UpstreamError, `expected UpstreamError, got ${err}`);
    assert.equal(err.kind, kind);
    if (httpStatus !== undefined) assert.equal(err.httpStatus, httpStatus);
    return true;
  });
}

test("sends one strict json_schema Chat Completions request", async () => {
  const calls = [];
  const fetch = async (url, init) => {
    calls.push({ url, init });
    return json(completion('{"a":1}'));
  };
  const result = await call(fetch);

  assert.equal(calls.length, 1);
  const { url, init } = calls[0];
  assert.equal(url, CHAT_COMPLETIONS_URL);
  assert.equal(init.method, "POST");
  assert.equal(init.headers.Authorization, "Bearer test-key");
  assert.equal(init.headers["Content-Type"], "application/json");
  assert.ok(init.signal instanceof AbortSignal);
  const body = JSON.parse(init.body);
  assert.deepEqual(body, {
    model: "test-model",
    messages: [{ role: "user", content: "hi" }],
    response_format: { type: "json_schema", json_schema: { name: "plan", strict: true, schema } },
    max_completion_tokens: 50,
    store: false,
  });

  assert.deepEqual(result, { value: { a: 1 }, usage: { promptTokens: 120, completionTokens: 9 } });
});

test("reasoning_effort is sent only when configured", async () => {
  let body;
  const fetch = async (_url, init) => {
    body = JSON.parse(init.body);
    return json(completion('{"a":1}'));
  };
  await call(fetch, { reasoningEffort: "" });
  assert.ok(!("reasoning_effort" in body));
  await call(fetch, { reasoningEffort: "low" });
  assert.equal(body.reasoning_effort, "low");
});

test("a non-2xx response is an http error carrying the status", async () => {
  await rejectsWith(call(async () => json({ error: { message: "quota" } }, 429)), "http", 429);
  await rejectsWith(call(async () => json({}, 500)), "http", 500);
});

test("a slow upstream times out", async () => {
  const hang = (_url, init) =>
    new Promise((_resolve, reject) => {
      init.signal.addEventListener("abort", () => reject(init.signal.reason));
    });
  const started = Date.now();
  await rejectsWith(call(hang, { timeoutMs: 30 }), "timeout");
  assert.ok(Date.now() - started < 1000);
});

test("a failed connection is a network error", async () => {
  await rejectsWith(
    call(async () => {
      throw new TypeError("fetch failed");
    }),
    "network"
  );
});

test("refusals, truncation and unparseable output are rejected", async () => {
  await rejectsWith(
    call(async () => json({ choices: [{ finish_reason: "stop", message: { content: null, refusal: "No." } }] })),
    "refused"
  );
  await rejectsWith(call(async () => json(completion('{"a":', { finish_reason: "length" }))), "truncated");
  await rejectsWith(call(async () => json(completion("not json"))), "malformed");
  await rejectsWith(call(async () => json(completion("[1,2]"))), "malformed");
  await rejectsWith(call(async () => json(completion("null"))), "malformed");
  await rejectsWith(call(async () => json({ choices: [] })), "malformed");
  await rejectsWith(call(async () => json({})), "malformed");
  await rejectsWith(call(async () => new Response("<html>", { status: 200 })), "malformed");
});

test("usage is optional", async () => {
  const body = completion('{"a":2}');
  delete body.usage;
  const result = await call(async () => json(body));
  assert.deepEqual(result.usage, { promptTokens: undefined, completionTokens: undefined });
});
