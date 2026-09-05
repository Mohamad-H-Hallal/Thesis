"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");
const { pathToFileURL } = require("node:url");

const {
  collectFlutterPackages,
  collectNpmPackages,
  normalizeLicense,
  outputPathFrom,
} = require("./generate-dependency-license-report");

test("normalizes npm license metadata without approving it", () => {
  assert.equal(normalizeLicense(" MIT "), "MIT");
  assert.equal(normalizeLicense([{ type: "MIT" }, "Apache-2.0"]), "MIT OR Apache-2.0");
  assert.equal(normalizeLicense(null), null);
});

test("reports production npm packages and excludes development dependencies", () => {
  const packages = collectNpmPackages({
    packages: {
      "": { name: "application", version: "1.0.0" },
      "node_modules/runtime": { version: "2.0.0", license: "MIT" },
      "node_modules/dev-only": { version: "3.0.0", license: "MIT", dev: true },
    },
  });
  assert.deepEqual(packages, [
    {
      name: "runtime",
      version: "2.0.0",
      license: "MIT",
      reviewStatus: "review_required",
    },
  ]);
});

test("hashes Flutter license evidence and flags a missing license file", (context) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "terraleb-licenses-"));
  context.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const licensed = path.join(directory, "licensed");
  const unresolved = path.join(directory, "unresolved");
  fs.mkdirSync(licensed);
  fs.mkdirSync(unresolved);
  fs.writeFileSync(path.join(licensed, "pubspec.yaml"), "name: licensed\nversion: 1.2.3\n");
  fs.writeFileSync(path.join(licensed, "LICENSE"), "reviewed license fixture\n");
  fs.writeFileSync(path.join(unresolved, "pubspec.yaml"), "name: unresolved\nversion: 4.5.6\n");

  const packages = collectFlutterPackages(
    {
      packages: [
        { name: "licensed", rootUri: pathToFileURL(licensed).href },
        { name: "unresolved", rootUri: pathToFileURL(unresolved).href },
      ],
    },
    "application",
  );

  assert.match(packages[0].licenseSha256, /^[a-f0-9]{64}$/);
  assert.equal(packages[0].reviewStatus, "review_required");
  assert.equal(packages[1].licenseFile, null);
  assert.equal(packages[1].reviewStatus, "missing_license_file");
});

test("requires an explicit output path", () => {
  assert.throws(() => outputPathFrom([]), /--output/);
  assert.ok(path.isAbsolute(outputPathFrom(["--output", "release/out/licenses.json"])));
});
