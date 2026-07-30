import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const extractor = fileURLToPath(new URL("./extract.mjs", import.meta.url));

test("the CLI runs a workspace input through the extraction pipeline", async () => {
  const root = await mkdtemp(join(tmpdir(), "briefly-extractor-e2e-"));
  const input = join(root, "fixture");
  try {
    await mkdir(input);
    await writeFile(
      join(input, "input.json"),
      `${JSON.stringify({
        apiVersion: 1,
        id: "fixture",
        sourceType: "article",
        priority: 100,
        match: { hosts: ["example.com"], pathPrefixes: [] },
        entry: "input.mjs",
        fallback: "none"
      })}\n`
    );
    await writeFile(
      join(input, "input.mjs"),
      `export default {
        extract(request, briefly) {
          return briefly.extractHTML({
            url: request.url.href,
            html: \`<title>End-to-end article</title><article><p>\${"Useful content. ".repeat(30)}</p></article>\`
          });
        }
      };\n`
    );

    const { stdout } = await execFileAsync(process.execPath, [
      extractor,
      "--extensions",
      root,
      "https://example.com/article"
    ]);
    const result = JSON.parse(stdout);
    assert.equal(result.extractor, "fixture");
    assert.equal(result.title, "End-to-end article");
    assert.match(result.content, /Useful content/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("the CLI extracts a dropped PDF", async () => {
  const root = await mkdtemp(join(tmpdir(), "briefly-pdf-e2e-"));
  const path = join(root, "report.pdf");
  try {
    await writeFile(path, pdfBytes("Dropped PDF content.", "Dropped report"));
    const { stdout } = await execFileAsync(process.execPath, [extractor, "--file", path]);
    const result = JSON.parse(stdout);
    assert.equal(result.title, "Dropped report");
    assert.match(result.content, /Dropped PDF content/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

function pdfBytes(text, title) {
  const stream = `BT /F1 18 Tf 72 720 Td (${text}) Tj ET`;
  const objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    `<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`,
    `<< /Title (${title}) >>`
  ];
  let pdf = "%PDF-1.4\n";
  const offsets = [0];
  for (const [index, object] of objects.entries()) {
    offsets.push(Buffer.byteLength(pdf, "latin1"));
    pdf += `${index + 1} 0 obj\n${object}\nendobj\n`;
  }
  const xref = Buffer.byteLength(pdf, "latin1");
  pdf += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  pdf += offsets.slice(1).map((offset) => `${String(offset).padStart(10, "0")} 00000 n \n`).join("");
  pdf += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R /Info 6 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return new TextEncoder().encode(pdf);
}
