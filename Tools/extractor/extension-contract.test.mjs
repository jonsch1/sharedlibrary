import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  discoverWorkspaceInputs,
  matchesWorkspaceInput,
  readWorkspaceInputManifest
} from "./extension-contract.mjs";

test("workspace input manifests are validated and matched declaratively", async () => {
  const root = await mkdtemp(join(tmpdir(), "briefly-input-contract-"));
  try {
    const packageDirectory = await createPackage(root, "journal", {
      priority: 250,
      match: {
        hosts: ["journal.example", "*.journal.example"],
        pathPrefixes: ["/articles/"]
      }
    });
    const input = await readWorkspaceInputManifest(
      join(packageDirectory, "input.json")
    );

    assert.equal(input.id, "journal");
    assert.equal(input.priority, 250);
    assert.equal(
      matchesWorkspaceInput(
        input,
        "https://research.journal.example/articles/finding"
      ),
      true
    );
    assert.equal(
      matchesWorkspaceInput(input, "https://journal.example/about"),
      false
    );
    assert.equal(
      matchesWorkspaceInput(
        input,
        "https://journal.example.evil.test/articles/finding"
      ),
      false
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("workspace inputs are ordered by priority and invalid packages are diagnosed", async () => {
  const root = await mkdtemp(join(tmpdir(), "briefly-input-discovery-"));
  try {
    await createPackage(root, "lower", { priority: 10 });
    await createPackage(root, "higher", { priority: 500 });
    const invalid = join(root, "invalid");
    await mkdir(invalid);
    await writeFile(join(invalid, "input.json"), '{"apiVersion":2}\n');
    const diagnostics = [];

    const inputs = await discoverWorkspaceInputs(root, {
      onDiagnostic: (event) => diagnostics.push(event)
    });

    assert.deepEqual(
      inputs.map((input) => input.id),
      ["higher", "lower"]
    );
    assert.equal(diagnostics[0]?.kind, "extension-invalid");
    assert.equal(diagnostics[0]?.package, "invalid");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("workspace input entries cannot escape their package", async () => {
  const root = await mkdtemp(join(tmpdir(), "briefly-input-path-"));
  try {
    const packageDirectory = await createPackage(root, "escaping");
    await writeFile(join(root, "outside.mjs"), "export default {};\n");
    const manifestPath = join(packageDirectory, "input.json");
    const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
    manifest.entry = "../outside.mjs";
    await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);

    await assert.rejects(
      readWorkspaceInputManifest(manifestPath),
      /inside the input package/
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

async function createPackage(root, id, overrides = {}) {
  const directory = join(root, id);
  await mkdir(directory, { recursive: true });
  await writeFile(
    join(directory, "input.mjs"),
    'export default { extract() { return { content: "ok" }; } };\n'
  );
  const manifest = {
    apiVersion: 1,
    id,
    sourceType: "article",
    priority: 100,
    match: {
      hosts: ["example.com"],
      pathPrefixes: []
    },
    entry: "input.mjs",
    fallback: "builtin",
    ...overrides
  };
  await writeFile(
    join(directory, "input.json"),
    `${JSON.stringify(manifest, null, 2)}\n`
  );
  return directory;
}
