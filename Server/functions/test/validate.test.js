"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const L = require("../src/limits");
const { validatePlanRequest, validateLabelRequest, isJpegBase64 } = require("../src/validate");

// The first bytes of a JPEG (SOI + APP0) and its end marker. Enough for the check.
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0xff, 0xd9]).toString("base64");
const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00]).toString("base64");

const buttons = (n) => Array.from({ length: n }, (_, i) => ({ id: `id-${i}`, label: String(i) }));
const boxes = (n) => Array.from({ length: n }, (_, i) => ({ id: `b${i}`, x: 0.1, y: 0.2, w: 0.1, h: 0.05 }));

test("plan: accepts the contract example and trims the request", () => {
  const r = validatePlanRequest({
    request: "  cook for a minute and a half ",
    buttons: [
      { id: "A", label: "1" },
      { id: "B", label: " Start " },
    ],
  });
  assert.deepEqual(r, {
    ok: true,
    value: {
      request: "cook for a minute and a half",
      buttons: [
        { id: "A", label: "1" },
        { id: "B", label: "Start" },
      ],
    },
  });
});

test("plan: null, missing and blank labels all mean unlabeled", () => {
  const r = validatePlanRequest({
    request: "start",
    buttons: [{ id: "a", label: null }, { id: "b" }, { id: "c", label: "   " }],
  });
  assert.equal(r.ok, true);
  assert.deepEqual(r.value.buttons.map((b) => b.label), [null, null, null]);
});

test("plan: accepts zero buttons (the handler answers without the model)", () => {
  const r = validatePlanRequest({ request: "start", buttons: [] });
  assert.equal(r.ok, true);
  assert.deepEqual(r.value.buttons, []);
});

test("plan: request length is capped at 300 characters with a spoken reason", () => {
  assert.equal(validatePlanRequest({ request: "a".repeat(L.MAX_REQUEST_CHARS), buttons: [] }).ok, true);
  const r = validatePlanRequest({ request: "a".repeat(L.MAX_REQUEST_CHARS + 1), buttons: [] });
  assert.equal(r.ok, false);
  assert.match(r.say, /long/);
});

test("plan: an empty request asks the user to say it again", () => {
  const r = validatePlanRequest({ request: "   ", buttons: buttons(1) });
  assert.equal(r.ok, false);
  assert.match(r.say, /say it again/);
});

test("plan: at most 120 buttons", () => {
  assert.equal(validatePlanRequest({ request: "x", buttons: buttons(L.MAX_ITEMS) }).ok, true);
  assert.equal(validatePlanRequest({ request: "x", buttons: buttons(L.MAX_ITEMS + 1) }).ok, false);
});

test("plan: rejects malformed bodies", () => {
  const bad = [
    null,
    [],
    "text",
    {},
    { request: 5, buttons: [] },
    { request: "x" },
    { request: "x", buttons: {} },
    { request: "x", buttons: [null] },
    { request: "x", buttons: [{ label: "1" }] },
    { request: "x", buttons: [{ id: "", label: "1" }] },
    { request: "x", buttons: [{ id: 7, label: "1" }] },
    { request: "x", buttons: [{ id: "a".repeat(L.MAX_ID_CHARS + 1), label: "1" }] },
    { request: "x", buttons: [{ id: "a", label: 1 }] },
    { request: "x", buttons: [{ id: "a", label: "x".repeat(L.MAX_BUTTON_LABEL_CHARS + 1) }] },
    { request: "x", buttons: [{ id: "a", label: "1" }, { id: "a", label: "2" }] },
  ];
  for (const body of bad) {
    const r = validatePlanRequest(body);
    assert.equal(r.ok, false, JSON.stringify(body));
    assert.equal(typeof r.detail, "string");
  }
});

test("plan: error details never echo the caller's values", () => {
  const secretId = "SECRET-ID-123";
  const r = validatePlanRequest({ request: "x", buttons: [{ id: secretId }, { id: secretId }] });
  assert.equal(r.ok, false);
  assert.ok(!r.detail.includes(secretId));
});

test("label: accepts the contract example", () => {
  const r = validateLabelRequest({ image: JPEG, boxes: [{ id: "b1", x: 0.1, y: 0.2, w: 0.1, h: 0.05, extra: 1 }] });
  assert.deepEqual(r, { ok: true, value: { image: JPEG, boxes: [{ id: "b1", x: 0.1, y: 0.2, w: 0.1, h: 0.05 }] } });
});

test("label: image must be bare base64 of a JPEG", () => {
  assert.equal(isJpegBase64(JPEG), true);
  assert.equal(isJpegBase64(PNG), false);
  assert.equal(isJpegBase64(""), false);
  assert.equal(isJpegBase64(`data:image/jpeg;base64,${JPEG}`), false);
  assert.equal(isJpegBase64(JPEG.slice(0, 10) + "\n" + JPEG.slice(10)), false);
  assert.equal(isJpegBase64(JPEG.slice(0, -1)), false); // length not a multiple of 4
  assert.equal(validateLabelRequest({ image: 12, boxes: [] }).ok, false);
});

test("label: an oversized image is a 413 with a spoken reason", () => {
  const big = "/9j/" + "A".repeat(L.MAX_IMAGE_BASE64_CHARS);
  const r = validateLabelRequest({ image: big, boxes: [] });
  assert.equal(r.ok, false);
  assert.equal(r.code, "too_large");
  assert.match(r.say, /photo/);
});

test("label: at most 120 boxes, ids unique", () => {
  assert.equal(validateLabelRequest({ image: JPEG, boxes: boxes(L.MAX_ITEMS) }).ok, true);
  assert.equal(validateLabelRequest({ image: JPEG, boxes: boxes(L.MAX_ITEMS + 1) }).ok, false);
  const dup = [boxes(1)[0], boxes(1)[0]];
  assert.equal(validateLabelRequest({ image: JPEG, boxes: dup }).ok, false);
});

test("label: coordinates are numbers in 0...1 with a non-zero size", () => {
  const box = (o) => ({ image: JPEG, boxes: [{ id: "b", x: 0.1, y: 0.2, w: 0.1, h: 0.05, ...o }] });
  assert.equal(validateLabelRequest(box({ x: 0, y: 0, w: 1, h: 1 })).ok, true);
  for (const o of [{ x: -0.01 }, { y: 1.01 }, { w: 0 }, { h: 0 }, { w: NaN }, { x: "0.1" }, { h: undefined }, { x: Infinity }]) {
    assert.equal(validateLabelRequest(box(o)).ok, false, JSON.stringify(o));
  }
});

test("label: accepts zero boxes (the handler answers without the model)", () => {
  assert.equal(validateLabelRequest({ image: JPEG, boxes: [] }).ok, true);
});
