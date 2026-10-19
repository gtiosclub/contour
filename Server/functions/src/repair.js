"use strict";

// Turns the model's answer into a contract response. The model answers with
// 1-based numbers (see prompts.js); only numbers that point at something the
// caller sent survive, so every id in a response came from the request.

const L = require("./limits");

const CANNOT_PLAN = "Sorry, I couldn't work out which buttons to press for that.";
const NO_BUTTONS = "I can't see any buttons yet. Please scan the panel again.";

// Collapse whitespace, trim, and cut to max characters (by code point).
function cleanText(value, max) {
  if (typeof value !== "string") return "";
  return Array.from(value.replace(/\s+/g, " ").trim()).slice(0, max).join("").trim();
}

function pick(list, n) {
  return Number.isInteger(n) && n >= 1 && n <= list.length ? list[n - 1] : undefined;
}

// "Press Start." / "Press Popcorn, then Start." / "Press 1, 3, 0, then Start."
function sayForSteps(labels) {
  const names = labels.map((l) => l || "the unlabeled button");
  if (names.length === 1) return `Press ${names[0]}.`;
  return `Press ${names.slice(0, -1).join(", ")}, then ${names[names.length - 1]}.`;
}

// buttons: the validated request buttons, in request order.
// answer:  the parsed model output ({ steps, say }).
function repairPlan(buttons, answer) {
  const raw = Array.isArray(answer && answer.steps) ? answer.steps : [];

  if (raw.length === 0) {
    return { steps: [], say: cleanText(answer && answer.say, L.MAX_SAY_CHARS) || CANNOT_PLAN };
  }

  const chosen = raw.map((n) => pick(buttons, n));
  // A sequence with a bad step is a wrong sequence: dropping "3" from 1, 3, 0
  // cooks for ten seconds instead of ninety. Refuse the whole plan instead.
  if (raw.length > L.MAX_STEPS || chosen.some((b) => b === undefined)) {
    return { steps: [], say: CANNOT_PLAN };
  }

  // The spoken sentence is built from the steps, so what the user hears always
  // matches what the vibration will guide them through.
  return {
    steps: chosen.map((b) => b.id),
    say: sayForSteps(chosen.map((b) => b.label)),
  };
}

// boxes:  the validated request boxes, in request order.
// answer: the parsed model output ({ boxes: [{ n, label, isButton }], start }).
// Boxes the model skipped or numbered wrongly are left out; output is in
// request order with no duplicates.
function repairLabels(boxes, answer) {
  const byIndex = new Map();
  for (const entry of Array.isArray(answer && answer.boxes) ? answer.boxes : []) {
    if (!entry || typeof entry !== "object") continue;
    const box = pick(boxes, entry.n);
    if (!box || byIndex.has(entry.n)) continue;
    byIndex.set(entry.n, {
      id: box.id,
      label: cleanText(entry.label, L.MAX_OUTPUT_LABEL_CHARS),
      isButton: entry.isButton === true,
    });
  }

  const labeled = [...byIndex.keys()].sort((a, b) => a - b).map((n) => byIndex.get(n));
  const startBox = pick(boxes, answer && answer.start);
  return { boxes: labeled, start: startBox ? startBox.id : null };
}

module.exports = { repairPlan, repairLabels, sayForSteps, cleanText, CANNOT_PLAN, NO_BUTTONS };
