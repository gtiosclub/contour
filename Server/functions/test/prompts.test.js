"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const { PLAN_SCHEMA, LABEL_SCHEMA, buildPlanMessages, buildLabelMessages } = require("../src/prompts");

test("plan messages: buttons are numbered by position and ids stay on the server", () => {
  const messages = buildPlanMessages({
    request: 'cook "for" a minute',
    buttons: [
      { id: "11111111-AAAA", label: "1" },
      { id: "22222222-BBBB", label: null },
    ],
  });
  assert.equal(messages.length, 2);
  assert.equal(messages[0].role, "system");
  assert.equal(messages[1].role, "user");
  const user = messages[1].content;
  assert.ok(user.includes(JSON.stringify('cook "for" a minute')), "request is JSON-quoted");
  assert.ok(user.includes('[{"n":1,"label":"1"},{"n":2,"label":null}]'));
  assert.ok(!user.includes("11111111") && !user.includes("22222222"));
});

test("label messages: boxes are numbered and rounded, the photo goes as a high-detail data URL", () => {
  const messages = buildLabelMessages({
    image: "/9j/AAAA",
    boxes: [{ id: "secret-box-id", x: 0.123456, y: 0.2, w: 0.1, h: 0.0549 }],
  });
  const [text, image] = messages[1].content;
  assert.equal(text.type, "text");
  assert.equal(text.text, 'Boxes: [{"n":1,"x":0.123,"y":0.2,"w":0.1,"h":0.055}]');
  assert.deepEqual(image, {
    type: "image_url",
    image_url: { url: "data:image/jpeg;base64,/9j/AAAA", detail: "high" },
  });
  assert.ok(!JSON.stringify(messages).includes("secret-box-id"));
});

// Strict structured outputs require every object to list all of its
// properties as required and to forbid additional ones.
function assertStrict(schema, path = "$") {
  if (schema.type === "object" || (Array.isArray(schema.type) && schema.type.includes("object"))) {
    assert.equal(schema.additionalProperties, false, `${path} additionalProperties`);
    assert.deepEqual([...schema.required].sort(), Object.keys(schema.properties).sort(), `${path} required`);
    for (const [k, v] of Object.entries(schema.properties)) assertStrict(v, `${path}.${k}`);
  }
  if (schema.items) assertStrict(schema.items, `${path}[]`);
}

test("schemas follow the strict structured-output rules", () => {
  assertStrict(PLAN_SCHEMA);
  assertStrict(LABEL_SCHEMA);
});
