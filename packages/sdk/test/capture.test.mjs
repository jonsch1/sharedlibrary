import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { once } from "node:events";
import { access, mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import test from "node:test";
import { Briefly, BrieflyError } from "@readbriefly/sdk";

const execFileAsync = promisify(execFile);
const helper = process.env.BRIEFLY_MCP_HELPER ??
  fileURLToPath(new URL("../../mcp/.build/debug/briefly-mcp", import.meta.url));
const quote = (value) => `'${value.replaceAll("'", `'"'"'`)}'`;

async function library(t) {
  await access(helper).catch(() => {
    throw new Error("Build the real helper first: swift build --package-path packages/mcp --product briefly-mcp. Or set BRIEFLY_MCP_HELPER.");
  });
  const directory = await mkdtemp(join(tmpdir(), "briefly-sdk-"));
  const database = join(directory, "library.sqlite3");
  const launcher = join(directory, "briefly-mcp");
  await writeFile(launcher, `#!/bin/sh\nexec ${quote(helper)} --library ${quote(database)}\n`, { mode: 0o700 });
  t.after(() => rm(directory, { recursive: true, force: true }));
  return { helperPath: launcher, database };
}

async function sourceTexts(database) {
  const { stdout } = await execFileAsync("sqlite3", [
    "-json", database,
    "SELECT documents.title, documents.source_url, document_texts.body FROM documents JOIN document_texts ON documents.id = document_texts.document_id WHERE variant = 'source' ORDER BY documents.title;",
  ]);
  return JSON.parse(stdout);
}

test("custom capture, native fallback, reads, and canonical updates use the real Briefly API", async (t) => {
  const { helperPath, database } = await library(t);
  const nativeText = "# Native capture\n\nThis source was fetched and extracted by the native Briefly input router.";
  const server = createServer((_request, response) => {
    response.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
    response.end(nativeText);
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const base = `http://127.0.0.1:${server.address().port}`;
  let content = "# Custom capture\n\nOnly the selected replies belong in this document.";
  const detailed = "A detailed discussion. ".repeat(650);
  const briefly = new Briefly({
    helperPath,
    adapters: [{
      id: "selected-discussion",
      matches: (url) => url.hostname === "127.0.0.1" && url.pathname === "/discussion",
      extract: () => ({ title: "Custom capture", content, concise: "Selected replies summary.", detailed }),
    }],
  });
  t.after(async () => {
    await briefly.close();
    await new Promise((resolve) => server.close(resolve));
  });

  const preview = await briefly.preview(`${base}/discussion`);
  assert.equal(preview.kind, "custom");
  assert.equal(preview.document.url, `${base}/discussion`);
  assert.equal(preview.document.content, content);
  assert.deepEqual((await briefly.search()).items, []);

  const saved = await briefly.capture(`${base}/discussion`);
  assert.equal(saved.status, "ready");
  assert.equal((await briefly.read({ id: saved.id })).text, "Selected replies summary.");
  const first = await briefly.read({ id: saved.id, detail: true });
  assert.equal(first.next, 12000);
  const second = await briefly.read({ id: saved.id, detail: true, cursor: first.next });
  assert.equal(first.text + second.text, detailed.trim());
  assert.equal((await briefly.search({ q: "Selected replies", limit: 1 })).items[0].id, saved.id);

  content = "# Updated custom capture\n\nNew replies from the same discussion.";
  const updated = await briefly.capture(`${base}/discussion`);
  assert.equal(updated.id, saved.id);
  assert.deepEqual(await sourceTexts(database), [{
    title: "Custom capture", source_url: `${base}/discussion`, body: content,
  }]);

  assert.deepEqual(await briefly.preview(`${base}/native.txt`), { kind: "native", url: `${base}/native.txt` });
  const native = await briefly.capture(`${base}/native.txt`);
  assert.equal(native.status, "processing");
  assert.equal((await briefly.read({ id: native.id })).status, "processing");
  assert.equal((await sourceTexts(database)).find((item) => item.title === "Native capture").body, nativeText);

  await briefly.save({ title: "Custom capture", content: "Replacement source", url: `${base}/discussion` });
  assert.equal((await briefly.read({ id: saved.id })).status, "processing");
  await assert.rejects(briefly.read({ id: "missing-document" }), (error) =>
    error instanceof BrieflyError && error.code === "not_found");
  await briefly.close();
  await assert.rejects(briefly.save({ title: "Closed", content: "Must not save" }), { code: "client_closed" });
});

test("preview needs no app and failed custom handling preserves saved content", async (t) => {
  const offline = new Briefly({
    helperPath: "/no-such-briefly-helper",
    adapters: [{ id: "offline", matches: () => true, extract: () => ({ title: "Preview", content: "Read without saving" }) }],
  });
  t.after(() => offline.close());
  assert.equal((await offline.preview("https://example.com/item")).document.content, "Read without saving");

  const { helperPath, database } = await library(t);
  let broken = false;
  const briefly = new Briefly({
    helperPath,
    adapters: [
      {
        id: "override",
        matches: (url) => url.hostname === "example.com",
        extract: () => {
          if (broken) throw new Error("Source layout changed");
          return { title: "Good source", content: "Keep this original", concise: "Keep this summary" };
        },
      },
      { id: "lower-priority", matches: () => true, extract: () => ({ title: "Wrong source", content: "Must not replace good content" }) },
    ],
  });
  t.after(() => briefly.close());
  const saved = await briefly.capture("https://example.com/item");
  broken = true;
  await assert.rejects(briefly.capture("https://example.com/item"), { code: "adapter_failed" });
  await assert.rejects(briefly.save({ title: "Invalid", content: "", url: "https://example.com/item" }), { code: "invalid_input" });
  assert.equal((await briefly.read({ id: saved.id })).text, "Keep this summary");
  assert.deepEqual(await sourceTexts(database), [{
    title: "Good source", source_url: "https://example.com/item", body: "Keep this original",
  }]);
});
