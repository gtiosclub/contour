"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const L = require("../src/limits");
const { repairPlan, repairLabels, sayForSteps, cleanText, CANNOT_PLAN } = require("../src/repair");

const keypad = ["1", "2", "3", "0", "Start", "Popcorn", null].map((label, i) => ({ id: `id-${i}`, label }));
// n:          1    2    3    4      5         6       7

test("plan: numbers map back to the caller's ids, repeats kept, in order", () => {
  const r = repairPlan(keypad, { steps: [1, 3, 4, 5], say: "ignored" });
  assert.deepEqual(r, { steps: ["id-0", "id-2", "id-3", "id-4"], say: "Press 1, 3, 0, then Start." });
  const twice = repairPlan(keypad, { steps: [1, 1, 4, 5], say: "" });
  assert.deepEqual(twice.steps, ["id-0", "id-0", "id-3", "id-4"]);
});

test("plan: the spoken sentence always matches the steps", () => {
  assert.equal(sayForSteps(["Popcorn"]), "Press Popcorn.");
  assert.equal(sayForSteps(["Popcorn", "Start"]), "Press Popcorn, then Start.");
  assert.equal(sayForSteps(["1", null]), "Press 1, then the unlabeled button.");
  // The model's own sentence is not used when there are steps.
  const r = repairPlan(keypad, { steps: [6], say: "Press 2 then Start." });
  assert.equal(r.say, "Press Popcorn.");
});

test("plan: a bad step refuses the whole plan instead of dropping it", () => {
  for (const steps of [[1, 99, 5], [0], [1, -1], [1.5], ["1"], [null], [8]]) {
    assert.deepEqual(repairPlan(keypad, { steps, say: "Press 1." }), { steps: [], say: CANNOT_PLAN }, JSON.stringify(steps));
  }
});

test("plan: an implausibly long plan is refused", () => {
  const steps = Array(L.MAX_STEPS + 1).fill(1);
  assert.deepEqual(repairPlan(keypad, { steps, say: "" }), { steps: [], say: CANNOT_PLAN });
  assert.equal(repairPlan(keypad, { steps: Array(L.MAX_STEPS).fill(1), say: "" }).steps.length, L.MAX_STEPS);
});

test("plan: no steps keeps the model's reason, cleaned and capped", () => {
  assert.deepEqual(repairPlan(keypad, { steps: [], say: "  This microwave has\nno defrost button. " }), {
    steps: [],
    say: "This microwave has no defrost button.",
  });
  assert.equal(repairPlan(keypad, { steps: [], say: "x".repeat(500) }).say.length, L.MAX_SAY_CHARS);
  assert.equal(repairPlan(keypad, { steps: [], say: "   " }).say, CANNOT_PLAN);
  assert.equal(repairPlan(keypad, {}).say, CANNOT_PLAN);
  assert.equal(repairPlan(keypad, null).say, CANNOT_PLAN);
});

const boxes = ["b1", "b2", "b3"].map((id) => ({ id, x: 0, y: 0, w: 0.1, h: 0.1 }));

test("label: numbers map back to ids, in request order", () => {
  const r = repairLabels(boxes, {
    boxes: [
      { n: 3, label: "Start", isButton: true },
      { n: 1, label: "Popcorn", isButton: true },
      { n: 2, label: "", isButton: false },
    ],
    start: 3,
  });
  assert.deepEqual(r, {
    boxes: [
      { id: "b1", label: "Popcorn", isButton: true },
      { id: "b2", label: "", isButton: false },
      { id: "b3", label: "Start", isButton: true },
    ],
    start: "b3",
  });
});

test("label: unknown and duplicate numbers are dropped, first answer wins", () => {
  const r = repairLabels(boxes, {
    boxes: [
      { n: 1, label: "First", isButton: true },
      { n: 1, label: "Second", isButton: false },
      { n: 4, label: "Invented", isButton: true },
      { n: 0, label: "Zero", isButton: true },
      { n: "2", label: "String", isButton: true },
      null,
    ],
    start: null,
  });
  assert.deepEqual(r, { boxes: [{ id: "b1", label: "First", isButton: true }], start: null });
});

test("label: start must point at a box that was sent", () => {
  for (const start of [0, 4, -1, 1.5, "1", undefined, null]) {
    assert.equal(repairLabels(boxes, { boxes: [], start }).start, null, String(start));
  }
  assert.equal(repairLabels(boxes, { boxes: [], start: 2 }).start, "b2");
});

test("label: labels are cleaned and capped, isButton must be exactly true", () => {
  const r = repairLabels(boxes, {
    boxes: [
      { n: 1, label: "  Add\n30   Sec ", isButton: "yes" },
      { n: 2, label: "y".repeat(100), isButton: true },
      { n: 3, label: 42, isButton: 1 },
    ],
    start: null,
  });
  assert.deepEqual(r.boxes[0], { id: "b1", label: "Add 30 Sec", isButton: false });
  assert.equal(r.boxes[1].label.length, L.MAX_OUTPUT_LABEL_CHARS);
  assert.deepEqual(r.boxes[2], { id: "b3", label: "", isButton: false });
});

test("label: a missing boxes field gives an empty list", () => {
  assert.deepEqual(repairLabels(boxes, {}), { boxes: [], start: null });
});

test("cleanText cuts by character, not UTF-16 unit", () => {
  assert.equal(cleanText("🍿🍿🍿", 2), "🍿🍿");
  assert.equal(cleanText(undefined, 5), "");
});
