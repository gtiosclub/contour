"use strict";

// The whole request path for POST /plan and POST /label, with every outside
// dependency passed in (fetch, App Check verification, config, logging, clock)
// so it runs offline under node --test. index.js is the Firebase adapter.
//
// Order: route -> method -> body size -> App Check -> rate limit -> validation
// -> model -> repair. Every response body carries a short `say` sentence the
// app can read aloud, and error bodies keep the success shape (steps: [] or
// boxes: [] / start: null) so one decoder handles every status.

const L = require("./limits");
const { validatePlanRequest, validateLabelRequest } = require("./validate");
const { PLAN_SCHEMA, LABEL_SCHEMA, buildPlanMessages, buildLabelMessages } = require("./prompts");
const { repairPlan, repairLabels, NO_BUTTONS } = require("./repair");
const { completeJson, UpstreamError } = require("./openai");
const { createRateLimiter, clientIp } = require("./rateLimit");

const APP_CHECK_HEADER = "x-firebase-appcheck";
const REFUSED = "Sorry, I can't help with that.";

const ERRORS = {
  not_found: [404, "Sorry, something went wrong. Please try again."],
  method_not_allowed: [405, "Sorry, something went wrong. Please try again."],
  too_large: [413, "That was too much to send. Please try again."],
  unauthorized: [401, "Sorry, Contour couldn't verify this app."],
  rate_limited: [429, "Too many requests. Please wait a moment and try again."],
  invalid_request: [400, "Sorry, something went wrong. Please try again."],
  misconfigured: [500, "Sorry, the assistant isn't set up yet."],
  upstream_timeout: [504, "That took too long. Please try again."],
  upstream_error: [502, "Sorry, I couldn't reach the assistant. Please try again."],
  internal: [500, "Sorry, something went wrong. Please try again."],
};

const ROUTES = {
  plan: { maxBodyBytes: L.MAX_PLAN_BODY_BYTES, empty: { steps: [] } },
  label: { maxBodyBytes: L.MAX_LABEL_BODY_BYTES, empty: { boxes: [], start: null } },
};

// The bypass only works inside the Functions emulator, which sets
// FUNCTIONS_EMULATOR=true. A deployed function ignores APPCHECK_BYPASS.
function appCheckBypassEnabled(env) {
  return env.FUNCTIONS_EMULATOR === "true" && env.APPCHECK_BYPASS === "true";
}

// The last path segment names the route, so "/plan" (emulator, run.app URL)
// and "/api/plan" both work.
function routeOf(path) {
  const last = String(path || "").replace(/\/+$/, "").split("/").pop();
  return Object.hasOwn(ROUTES, last) ? last : null;
}

function errorResponse(route, code, { say, detail, headers } = {}) {
  const [status, defaultSay] = ERRORS[code];
  const body = { ...(route ? ROUTES[route].empty : {}), say: say || defaultSay, error: code };
  if (detail) body.detail = detail;
  return { status, outcome: code, headers: headers || {}, body };
}

function ok(body, outcome = "ok") {
  return { status: 200, outcome, headers: {}, body };
}

function createHandler({
  fetch,
  verifyAppCheck,
  appCheckBypass = false,
  getConfig,
  log = () => {},
  now = Date.now,
  timeoutMs = L.UPSTREAM_TIMEOUT_MS,
  limiters = {
    plan: createRateLimiter({ ...L.RATE_LIMITS.plan, now }),
    label: createRateLimiter({ ...L.RATE_LIMITS.label, now }),
  },
}) {
  // Calls the model. Resolves to { value } or, when there is nothing to
  // repair, to { response } with the error to send.
  async function ask(route, messages, schema, entry) {
    let config;
    try {
      config = getConfig() || {};
    } catch {
      config = {};
    }
    if (!config.apiKey || !config.model) return { response: errorResponse(route, "misconfigured") };

    const started = now();
    try {
      const { value, usage } = await completeJson({
        fetch,
        apiKey: config.apiKey,
        model: config.model,
        reasoningEffort: config.reasoningEffort,
        messages,
        schemaName: route,
        schema,
        maxCompletionTokens: L.MAX_COMPLETION_TOKENS[route],
        timeoutMs,
      });
      entry.promptTokens = usage.promptTokens;
      entry.completionTokens = usage.completionTokens;
      return { value };
    } catch (err) {
      if (!(err instanceof UpstreamError)) throw err;
      entry.upstream = err.kind;
      if (err.httpStatus) entry.upstreamStatus = err.httpStatus;
      if (err.kind === "timeout") return { response: errorResponse(route, "upstream_timeout") };
      // A refused plan is a plan the server can't do: 200 with no steps.
      if (err.kind === "refused" && route === "plan") {
        return { response: ok({ steps: [], say: REFUSED }, "refused") };
      }
      return { response: errorResponse(route, "upstream_error") };
    } finally {
      entry.upstreamMs = now() - started;
    }
  }

  async function plan(body, entry) {
    const v = validatePlanRequest(body);
    if (!v.ok) return errorResponse("plan", v.code || "invalid_request", v);
    const { request, buttons } = v.value;
    entry.buttons = buttons.length;
    entry.requestChars = request.length;
    if (buttons.length === 0) return ok({ steps: [], say: NO_BUTTONS }, "no_buttons");

    const answer = await ask("plan", buildPlanMessages(v.value), PLAN_SCHEMA, entry);
    if (answer.response) return answer.response;
    const result = repairPlan(buttons, answer.value);
    entry.steps = result.steps.length;
    return ok(result, result.steps.length > 0 ? "ok" : "cannot");
  }

  async function label(body, entry) {
    const v = validateLabelRequest(body);
    if (!v.ok) return errorResponse("label", v.code || "invalid_request", v);
    const { image, boxes } = v.value;
    entry.boxes = boxes.length;
    entry.imageBytes = Math.floor((image.length * 3) / 4);
    if (boxes.length === 0) return ok({ boxes: [], start: null }, "no_boxes");

    const answer = await ask("label", buildLabelMessages(v.value), LABEL_SCHEMA, entry);
    if (answer.response) return answer.response;
    const result = repairLabels(boxes, answer.value);
    entry.labeled = result.boxes.length;
    entry.hasStart = result.start !== null;
    return ok(result);
  }

  async function run(req, route, entry) {
    if (!route) return errorResponse(null, "not_found");
    if (req.method !== "POST") {
      return errorResponse(route, "method_not_allowed", { headers: { Allow: "POST" } });
    }
    if (req.bodyBytes > ROUTES[route].maxBodyBytes) return errorResponse(route, "too_large");

    const headers = req.headers || {};
    if (appCheckBypass) {
      entry.appCheck = "bypassed";
    } else {
      const token = headers[APP_CHECK_HEADER];
      if (typeof token !== "string" || token.length === 0) return errorResponse(route, "unauthorized");
      try {
        await verifyAppCheck(token);
      } catch {
        return errorResponse(route, "unauthorized");
      }
    }

    const limit = limiters[route].hit(clientIp(headers, req.remoteAddress));
    if (!limit.allowed) {
      return errorResponse(route, "rate_limited", {
        headers: { "Retry-After": String(limit.retryAfterSeconds) },
      });
    }

    return route === "plan" ? plan(req.body, entry) : label(req.body, entry);
  }

  // req: { method, path, headers, body, bodyBytes, remoteAddress }
  // Never throws. Resolves to { status, headers, body }.
  return async function handle(req) {
    const started = now();
    const route = routeOf(req.path);
    // Only sizes, counts, timings and outcomes go in here. Never the image,
    // the request text, labels or ids.
    const entry = { route: route || "unknown", bodyBytes: req.bodyBytes || 0 };
    let result;
    try {
      result = await run(req, route, entry);
    } catch (err) {
      entry.error = err && err.name;
      result = errorResponse(route, "internal");
    }
    entry.status = result.status;
    entry.outcome = result.outcome;
    entry.totalMs = now() - started;
    log(entry);
    return {
      status: result.status,
      headers: { "Cache-Control": "no-store", ...result.headers },
      body: result.body,
    };
  };
}

module.exports = { createHandler, appCheckBypassEnabled, routeOf, APP_CHECK_HEADER };
