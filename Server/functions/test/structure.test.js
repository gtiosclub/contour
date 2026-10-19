"use strict";

// Keeps the split honest: src/ stays dependency-free so it tests offline, and
// only index.js touches Firebase.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { builtinModules } = require("node:module");
const { execFileSync } = require("node:child_process");

const root = path.join(__dirname, "..");
const requires = (file) =>
  [...fs.readFileSync(file, "utf8").matchAll(/require\(\s*["']([^"']+)["']\s*\)/g)].map((m) => m[1]);

test("src/ requires only node built-ins and its own files", () => {
  const dir = path.join(root, "src");
  for (const name of fs.readdirSync(dir).filter((f) => f.endsWith(".js"))) {
    for (const id of requires(path.join(dir, name))) {
      const ok = id.startsWith("./") || id.startsWith("node:") || builtinModules.includes(id);
      assert.ok(ok, `src/${name} requires ${id}`);
    }
  }
});

test("package.json depends on Firebase only and tests with node --test", () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
  assert.deepEqual(Object.keys(pkg.dependencies).sort(), ["firebase-admin", "firebase-functions"]);
  assert.equal(pkg.devDependencies, undefined);
  assert.equal(pkg.scripts.test, "node --test");
});

test("index.js parses", () => {
  execFileSync(process.execPath, ["--check", path.join(root, "index.js")]);
});
