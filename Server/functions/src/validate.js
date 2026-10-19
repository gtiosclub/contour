"use strict";

// Request validation for /plan and /label. Returns either
//   { ok: true, value }                  the cleaned request
//   { ok: false, detail, say?, code? }   detail is for developers and never
//                                        echoes the caller's data back; code
//                                        overrides "invalid_request".

const L = require("./limits");

function fail(detail, say, code) {
  const result = { ok: false, detail };
  if (say) result.say = say;
  if (code) result.code = code;
  return result;
}

function isPlainObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

function checkId(id, where, seen) {
  if (typeof id !== "string" || id.length === 0 || id.length > L.MAX_ID_CHARS) {
    return `${where}.id must be a non-empty string of at most ${L.MAX_ID_CHARS} characters`;
  }
  if (seen.has(id)) return `${where}.id is a duplicate`;
  seen.add(id);
  return null;
}

function checkList(list, name) {
  if (!Array.isArray(list)) return `${name} must be an array`;
  if (list.length > L.MAX_ITEMS) return `${name} may have at most ${L.MAX_ITEMS} entries`;
  return null;
}

function validatePlanRequest(body) {
  if (!isPlainObject(body)) return fail("body must be a JSON object");

  if (typeof body.request !== "string") return fail("request must be a string");
  const request = body.request.trim();
  if (request.length === 0) return fail("request is empty", "I didn't catch that. Please say it again.");
  if (request.length > L.MAX_REQUEST_CHARS) {
    return fail(
      `request may be at most ${L.MAX_REQUEST_CHARS} characters`,
      "That was a bit long. Please say it more briefly."
    );
  }

  const listError = checkList(body.buttons, "buttons");
  if (listError) return fail(listError);

  const seen = new Set();
  const buttons = [];
  for (let i = 0; i < body.buttons.length; i++) {
    const b = body.buttons[i];
    const where = `buttons[${i}]`;
    if (!isPlainObject(b)) return fail(`${where} must be an object`);
    const idError = checkId(b.id, where, seen);
    if (idError) return fail(idError);
    // SurfaceMap.Button.label is optional: null, missing or "" all mean
    // "there is a button here but it could not be read".
    let label = null;
    if (b.label !== undefined && b.label !== null) {
      if (typeof b.label !== "string" || b.label.length > L.MAX_BUTTON_LABEL_CHARS) {
        return fail(`${where}.label must be a string of at most ${L.MAX_BUTTON_LABEL_CHARS} characters, or null`);
      }
      label = b.label.trim() || null;
    }
    buttons.push({ id: b.id, label });
  }

  return { ok: true, value: { request, buttons } };
}

const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/;

function isJpegBase64(s) {
  if (s.length === 0 || s.length % 4 !== 0 || !BASE64.test(s)) return false;
  const head = Buffer.from(s.slice(0, 8), "base64");
  return head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff;
}

function isUnit(v) {
  return typeof v === "number" && Number.isFinite(v) && v >= 0 && v <= 1;
}

function validateLabelRequest(body) {
  if (!isPlainObject(body)) return fail("body must be a JSON object");

  if (typeof body.image !== "string") return fail("image must be a base64 string");
  if (body.image.length > L.MAX_IMAGE_BASE64_CHARS) {
    return fail(
      `image may be at most ${L.MAX_IMAGE_BASE64_CHARS} base64 characters`,
      "That photo is too large. Please try again.",
      "too_large"
    );
  }
  if (!isJpegBase64(body.image)) {
    return fail("image must be plain base64 (no data: prefix, no line breaks) of a JPEG");
  }

  const listError = checkList(body.boxes, "boxes");
  if (listError) return fail(listError);

  const seen = new Set();
  const boxes = [];
  for (let i = 0; i < body.boxes.length; i++) {
    const b = body.boxes[i];
    const where = `boxes[${i}]`;
    if (!isPlainObject(b)) return fail(`${where} must be an object`);
    const idError = checkId(b.id, where, seen);
    if (idError) return fail(idError);
    if (![b.x, b.y, b.w, b.h].every(isUnit) || b.w === 0 || b.h === 0) {
      return fail(`${where} needs x, y, w, h as numbers from 0 to 1, with w and h above 0`);
    }
    boxes.push({ id: b.id, x: b.x, y: b.y, w: b.w, h: b.h });
  }

  return { ok: true, value: { image: body.image, boxes } };
}

module.exports = { validatePlanRequest, validateLabelRequest, isJpegBase64 };
