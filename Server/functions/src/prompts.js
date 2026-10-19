"use strict";

// Prompts and output schemas for the model.
//
// The model never sees the caller's ids. Each button or box is shown as a
// number n (its 1-based position in the request) and the model answers with
// those numbers; repair.js maps them back. Short numbers cost fewer tokens than
// UUIDs, and a number outside 1...count is easy to reject.

const PLAN_SYSTEM = [
  "You operate the control panel of a microwave for a blind user.",
  "You get what the user said and the panel's buttons. Each button has a number n and the text printed on it; a null label means the text could not be read.",
  "Return steps: the n of each button to press, in order, so the microwave does what the user asked. Repeat an n to press that button more than once.",
  "Use only the n values in the list. Never make up a button.",
  "Cooking times are usually typed as digits, minutes then seconds: one and a half minutes is 1, 3, 0 and five minutes is 5, 0, 0. If the panel has a Time Cook or Cook Time button, press it before the digits. Finish with the button that starts cooking, such as Start.",
  "Prefer a dedicated button when it clearly matches the request, such as Popcorn.",
  "If this panel cannot do what was asked, or you are not sure which buttons to use, return an empty steps list.",
  "say is one short, plain sentence that will be read aloud. When steps is empty, say briefly why.",
].join("\n");

const LABEL_SYSTEM = [
  "You read a photo of an appliance control panel, usually a microwave, for a blind user.",
  "You get numbered boxes. Each box is a region of the photo that may be a control. x and y are the box's top-left corner and w and h its width and height, all as fractions of the photo's width and height, measured from the photo's top-left corner with y increasing downward.",
  "Return one entry for every box: its n, its label and isButton.",
  'label is what is printed on the control, written the way a person would say it, for example "Popcorn", "Start", "3" or "Add 30 Sec". For a control marked only with a symbol, give a short name for what it does, for example "Light". If you cannot read it, use an empty string.',
  "isButton is false when the box is not a control you can press, such as the display, a logo, a sticker or the door handle.",
  "start is the n of the button that starts cooking, usually labelled Start, or null if there is none.",
  "Use only the n values given. Never make up a box.",
].join("\n");

// Strict structured outputs: every property required, no extra properties.
// Kept to plain types so the schema is identical on every request.
const PLAN_SCHEMA = Object.freeze({
  type: "object",
  properties: {
    steps: { type: "array", items: { type: "integer" } },
    say: { type: "string" },
  },
  required: ["steps", "say"],
  additionalProperties: false,
});

const LABEL_SCHEMA = Object.freeze({
  type: "object",
  properties: {
    boxes: {
      type: "array",
      items: {
        type: "object",
        properties: {
          n: { type: "integer" },
          label: { type: "string" },
          isButton: { type: "boolean" },
        },
        required: ["n", "label", "isButton"],
        additionalProperties: false,
      },
    },
    start: { type: ["integer", "null"] },
  },
  required: ["boxes", "start"],
  additionalProperties: false,
});

const round3 = (v) => Math.round(v * 1000) / 1000;

function buildPlanMessages({ request, buttons }) {
  const list = buttons.map((b, i) => ({ n: i + 1, label: b.label }));
  return [
    { role: "system", content: PLAN_SYSTEM },
    {
      role: "user",
      content: `What the user said: ${JSON.stringify(request)}\nButtons: ${JSON.stringify(list)}`,
    },
  ];
}

function buildLabelMessages({ image, boxes }) {
  const list = boxes.map((b, i) => ({
    n: i + 1,
    x: round3(b.x),
    y: round3(b.y),
    w: round3(b.w),
    h: round3(b.h),
  }));
  return [
    { role: "system", content: LABEL_SYSTEM },
    {
      role: "user",
      content: [
        { type: "text", text: `Boxes: ${JSON.stringify(list)}` },
        // "high" because button text is small in a whole-panel photo.
        { type: "image_url", image_url: { url: `data:image/jpeg;base64,${image}`, detail: "high" } },
      ],
    },
  ];
}

module.exports = {
  PLAN_SCHEMA,
  LABEL_SCHEMA,
  buildPlanMessages,
  buildLabelMessages,
};
