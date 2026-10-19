"use strict";

// Firebase wiring only. Everything with logic is in src/, has no dependencies,
// and is covered by `node --test`. This file is only syntax-checked offline.

const { onRequest } = require("firebase-functions/https");
const { defineSecret, defineString } = require("firebase-functions/params");
const logger = require("firebase-functions/logger");
const { initializeApp } = require("firebase-admin/app");
const { getAppCheck } = require("firebase-admin/app-check");

const { createHandler, appCheckBypassEnabled } = require("./src/handler");

initializeApp();

// Set with `firebase functions:secrets:set OPENAI_API_KEY`. Never in the app.
const OPENAI_API_KEY = defineSecret("OPENAI_API_KEY");
// No default on purpose: set it in functions/.env (see README).
const OPENAI_MODEL = defineString("OPENAI_MODEL", {
  description: "OpenAI model id for /plan and /label: a small, fast model with image input.",
});

const appCheckBypass = appCheckBypassEnabled(process.env);
if (appCheckBypass) logger.warn("App Check bypass is on (emulator only).");

const handle = createHandler({
  fetch: globalThis.fetch,
  verifyAppCheck: (token) => getAppCheck().verifyToken(token),
  appCheckBypass,
  getConfig: () => ({
    apiKey: OPENAI_API_KEY.value(),
    model: OPENAI_MODEL.value(),
    // Optional, for reasoning models only (see README).
    reasoningEffort: process.env.OPENAI_REASONING_EFFORT || "",
  }),
  log: (entry) => {
    if (entry.status >= 500) logger.error("request", entry);
    else if (entry.status >= 400) logger.warn("request", entry);
    else logger.info("request", entry);
  },
});

// {base} = https://<region>-<project-id>.cloudfunctions.net/api
// POST {base}/plan and POST {base}/label
exports.api = onRequest(
  {
    secrets: [OPENAI_API_KEY],
    // Cost guard: at most this many instances, whatever the traffic.
    maxInstances: 3,
    // Above the 8 s model timeout plus App Check verification.
    timeoutSeconds: 20,
  },
  async (req, res) => {
    const result = await handle({
      method: req.method,
      path: req.path,
      headers: req.headers,
      body: req.body,
      bodyBytes: req.rawBody ? req.rawBody.length : 0,
      remoteAddress: req.socket ? req.socket.remoteAddress : undefined,
    });
    res.status(result.status).set(result.headers).json(result.body);
  }
);
