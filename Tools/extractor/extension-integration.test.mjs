import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

import { extractLink } from "./inputs/registry.mjs";

const execFileAsync = promisify(execFile);
const extractorPath = fileURLToPath(new URL("./extract.mjs", import.meta.url));

test("workspace inputs run before built-ins and are picked up without restart", async () => {
  const root = await mkdtemp(join(tmpdir(), "briefly-input-runtime-"));
  try {
    const packageDirectory = await createPackage(
      root,
      "custom-example",
      `export default {
        extract(request) {
          console.log("extension log");
          return {
            sourceURL: request.url.href,
            title: "First implementation",
            content: "First custom result."
          };
        }
      };`
    );

    const first = await extractLink("https://example.com/article", {
      extensionsDirectory: root
    });
    assert.equal(first.extractor, "custom-example");
    assert.equal(first.title, "First implementation");

    await writeFile(
      join(packageDirectory, "input.mjs"),
      `export default {
        extract(request) {
          return {
            sourceURL: request.url.href,
            title: "Updated implementation",
            content: "Updated custom result."
          };
        }
      };`
    );
    const updated = await extractLink("https://example.com/article", {
      extensionsDirectory: root
    });
    assert.equal(updated.title, "Updated implementation");
    assert.equal(updated.content, "Updated custom result.");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("workspace inputs receive the versioned HTML extraction API", async () => {
  const root = await mkdtemp(join(tmpdir(), "briefly-input-api-"));
  try {
    await createPackage(
      root,
      "html-api",
      `export default {
        extract(request, briefly) {
          const extracted = briefly.extractHTML({
            url: request.url.href,
            html: \`<html><head><title>Extension API</title></head><body><article><p>\${"Useful extension content. ".repeat(20)}</p></article></body></html>\`
          });
          return {
            sourceURL: request.url.href,
            title: extracted.title,
            content: extracted.content,
            metadata: { apiVersion: briefly.apiVersion }
          };
        }
      };`
    );

    const result = await extractLink("https://example.com/api", {
      extensionsDirectory: root
    });
    assert.equal(result.title, "Extension API");
    assert.equal(result.metadata.apiVersion, 1);
    assert.match(result.content, /Useful extension content/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("workspace input processes cannot read unrelated files or inherited secrets", async () => {
  const root = await mkdtemp(join(tmpdir(), "briefly-input-isolation-"));
  const outside = join(root, "outside-secret.txt");
  const secretName = `BRIEFLY_EXTENSION_SECRET_${process.pid}`;
  process.env[secretName] = "should-not-be-visible";
  try {
    await writeFile(outside, "private");
    const packages = join(root, "inputs");
    await createPackage(
      packages,
      "isolated",
      `import { readFile, writeFile } from "node:fs/promises";
       import { spawnSync } from "node:child_process";
       export default {
         async extract(request) {
           let fileAccess = "unexpected";
           let writeAccess = "unexpected";
           let childAccess = "unexpected";
           try {
             await readFile(${JSON.stringify(outside)}, "utf8");
           } catch (error) {
             fileAccess = error?.code ?? error?.name ?? "denied";
           }
           try {
             await writeFile(new URL("./created.txt", import.meta.url), "no");
           } catch (error) {
             writeAccess = error?.code ?? error?.name ?? "denied";
           }
           try {
             spawnSync(process.execPath, ["--version"]);
           } catch (error) {
             childAccess = error?.code ?? error?.name ?? "denied";
           }
           return {
             sourceURL: request.url.href,
             content: [
               String(process.env[${JSON.stringify(secretName)}] ?? "clean"),
               fileAccess,
               writeAccess,
               childAccess
             ].join(":")
           };
         }
       };`
    );

    const result = await extractLink("https://example.com/private", {
      extensionsDirectory: packages
    });
    assert.match(result.content, /^clean:/);
    assert.doesNotMatch(result.content, /unexpected/);
  } finally {
    delete process.env[secretName];
    await rm(root, { recursive: true, force: true });
  }
});

test("failing workspace inputs fall back to the built-in pipeline when configured", async () => {
  const root = await mkdtemp(join(tmpdir(), "briefly-input-fallback-"));
  try {
    await createPackage(
      root,
      "broken-example",
      'export default { extract() { throw new Error("site response changed"); } };'
    );
    const progress = [];
    const result = await extractLink("https://example.com/article", {
      extensionsDirectory: root,
      fetchImpl: async () => htmlResponse(),
      onProgress: (event) => progress.push(event)
    });

    assert.equal(result.extractor, "generic-html");
    const fallback = progress.find((event) => event.kind === "input-fallback");
    assert.ok(fallback);
    assert.match(fallback.reason ?? "", /site response changed/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("workspace inputs can disable fallback and expose a phased diagnostic", async () => {
  const root = await mkdtemp(join(tmpdir(), "briefly-input-no-fallback-"));
  try {
    await createPackage(
      root,
      "strict-example",
      'export default { extract() { throw new Error("required API unavailable"); } };',
      { fallback: "none" }
    );

    await assert.rejects(
      extractLink("https://example.com/article", {
        extensionsDirectory: root
      }),
      /Workspace input "strict-example" failed during execution: required API unavailable/
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("the extractor CLI accepts a workspace extension directory", async () => {
  const root = await mkdtemp(join(tmpdir(), "briefly-input-cli-"));
  try {
    await createPackage(
      root,
      "cli-example",
      `export default {
        extract(request) {
          return {
            sourceURL: request.url.href,
            title: "CLI extension",
            content: "CLI extension result."
          };
        }
      };`
    );
    const { stdout } = await execFileAsync(process.execPath, [
      extractorPath,
      "--extensions",
      root,
      "https://example.com/cli"
    ]);
    const result = JSON.parse(stdout);
    assert.equal(result.extractor, "cli-example");
    assert.equal(result.title, "CLI extension");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

async function createPackage(root, id, source, overrides = {}) {
  const directory = join(root, id);
  await mkdir(directory, { recursive: true });
  await writeFile(join(directory, "input.mjs"), `${source}\n`);
  await writeFile(
    join(directory, "input.json"),
    `${JSON.stringify(
      {
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
      },
      null,
      2
    )}\n`
  );
  return directory;
}

function htmlResponse() {
  return {
    ok: true,
    status: 200,
    statusText: "OK",
    url: "https://example.com/article",
    headers: new Headers({ "content-type": "text/html" }),
    text: async () =>
      "<html><head><title>Fallback</title></head><body><article><p>Built-in fallback content.</p></article></body></html>"
  };
}
