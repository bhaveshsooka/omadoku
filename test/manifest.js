// Checks manifest.json against itself and against the files it names.
//
//   node test/manifest.js
//
// The shell reads this file once at load; a mistake in it is not a warning,
// it is a plugin that does not appear. The marketplace validates it too, and
// a listing update fails on the exact commit it was run against - so the
// cheapest place to catch a mistake is here.

"use strict";

const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "..");
let failures = 0;
let checks = 0;

function check(condition, message) {
  checks++;
  if (!condition) {
    failures++;
    console.log("FAIL  " + message);
  }
}

let manifest;
try {
  manifest = JSON.parse(fs.readFileSync(path.join(root, "manifest.json"), "utf8"));
} catch (error) {
  console.log("FAIL  manifest.json is not valid JSON: " + error.message);
  process.exit(1);
}
check(true, "manifest.json parses");

for (const key of ["schemaVersion", "id", "name", "version", "author", "license", "kinds", "entryPoints"]) {
  check(manifest[key] !== undefined, `manifest declares ${key}`);
}

check(manifest.schemaVersion === 1, "schemaVersion is 1");
check(/^\d+\.\d+\.\d+$/.test(String(manifest.version)),
      `version "${manifest.version}" is three dot-separated numbers`);
check(/^[a-z0-9.]+$/.test(String(manifest.id)), `id "${manifest.id}" is a reverse-domain name`);

// An entry point naming a file that is not there is a plugin that loads to
// nothing, and neither the shell nor the marketplace checks it for us.
for (const [kind, file] of Object.entries(manifest.entryPoints || {})) {
  check(fs.existsSync(path.join(root, file)), `entry point for ${kind} exists: ${file}`);
}

const widget = manifest.barWidget || {};
const schema = widget.schema || [];
const defaults = widget.defaults || {};
const byKey = {};
for (const entry of schema) {
  check(byKey[entry.key] === undefined, `setting ${entry.key} is declared once`);
  byKey[entry.key] = entry;
}

// The two halves are read by different things - `defaults` by the shell when a
// widget is added, `schema` by the settings UI - so they drift silently unless
// something compares them.
for (const [key, value] of Object.entries(defaults)) {
  const entry = byKey[key];
  check(entry !== undefined, `default "${key}" has a matching schema entry`);
  if (entry) {
    check(JSON.stringify(entry.defaultValue) === JSON.stringify(value),
          `default for "${key}" agrees with its schema entry ` +
          `(${JSON.stringify(value)} vs ${JSON.stringify(entry.defaultValue)})`);
  }
}
for (const entry of schema) {
  check(defaults[entry.key] !== undefined, `schema entry "${entry.key}" has a default`);

  if (entry.type === "enum") {
    check(Array.isArray(entry.options) && entry.options.length > 0,
          `enum "${entry.key}" lists its options`);
    check((entry.options || []).indexOf(entry.defaultValue) !== -1,
          `enum "${entry.key}" defaults to one of its own options`);
  }
  if (entry.type === "integer") {
    check(entry.defaultValue >= entry.min && entry.defaultValue <= entry.max,
          `integer "${entry.key}" defaults inside its own range`);
  }
}

console.log(failures ? `\n${failures} of ${checks} manifest checks FAILED`
                     : `\nall ${checks} manifest checks passed`);
process.exit(failures ? 1 : 0);
