import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  extractGenericHTML,
  extractGenericHTMLFromSource
} from "./generic-html.mjs";
import { extractPDFFile } from "./pdf.mjs";

test("generic HTML extraction uses page metadata and readable article text", () => {
  const result = extractGenericHTMLFromSource(
    "https://example.com/posts/reliable-inputs",
    `<!doctype html>
      <html>
        <head>
          <title>Fallback title</title>
          <meta property="og:title" content="Reliable inputs">
          <meta property="og:description" content="A useful extraction example.">
          <meta property="og:site_name" content="Example">
          <link rel="canonical" href="/canonical/reliable-inputs">
          <link rel="icon" href="/assets/favicon.png">
        </head>
        <body>
          <nav>Unrelated navigation</nav>
          <article>
            <h1>Reliable inputs</h1>
            <p>${"A deliberate input pipeline keeps fetching and extraction behavior understandable. ".repeat(6)}</p>
          </article>
        </body>
      </html>`
  );

  assert.equal(result.url, "https://example.com/posts/reliable-inputs");
  assert.equal(
    result.canonicalURL,
    "https://example.com/canonical/reliable-inputs"
  );
  assert.equal(result.title, "Reliable inputs");
  assert.equal(result.description, "A useful extraction example.");
  assert.equal(result.siteName, "Example");
  assert.equal(result.faviconURL, "https://example.com/assets/favicon.png");
  assert.match(result.content, /deliberate input pipeline/);
  assert.doesNotMatch(result.content, /Unrelated navigation/);
});

test("generic HTML extraction reads PDFs by content instead of file extension", async () => {
  const bytes = pdfBytes("Readable PDF content.", "A useful PDF");
  const result = await extractGenericHTML("https://example.com/download?id=42", {
    fetchImpl: async () =>
      binaryResponse(bytes, {
        contentType: "application/octet-stream",
        url: "https://cdn.example.com/report"
      })
  });

  assert.equal(result.title, "A useful PDF");
  assert.match(result.content, /Readable PDF content/);
  assert.equal(result.extractor, "pdf");
});

test("generic HTML extraction still rejects unsupported binary responses", async () => {
  await assert.rejects(
    extractGenericHTML("https://example.com/archive.zip", {
      fetchImpl: async () => response("PK", {
        contentType: "application/zip"
      })
    }),
    /Unsupported link content type: application\/zip/
  );
});

test("local PDF extraction reads a dropped file", async () => {
  const root = await mkdtemp(join(tmpdir(), "briefly-pdf-"));
  const path = join(root, "local-report.pdf");
  try {
    await writeFile(path, pdfBytes("Dropped PDF content.", "Dropped report"));
    const result = await extractPDFFile(path);
    assert.equal(result.title, "Dropped report");
    assert.match(result.content, /Dropped PDF content/);
  } finally {
    await rm(root, { recursive: true });
  }
});

function response(body, { contentType = "text/html", url = "https://example.com/" } = {}) {
  return {
    ok: true,
    status: 200,
    statusText: "OK",
    url,
    headers: new Headers({ "content-type": contentType }),
    text: async () => body
  };
}

function binaryResponse(bytes, options) {
  return {
    ok: true,
    status: 200,
    statusText: "OK",
    url: options.url,
    headers: new Headers({ "content-type": options.contentType }),
    arrayBuffer: async () =>
      bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
  };
}

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
  objects.forEach((object, index) => {
    offsets.push(Buffer.byteLength(pdf, "latin1"));
    pdf += `${index + 1} 0 obj\n${object}\nendobj\n`;
  });
  const xref = Buffer.byteLength(pdf, "latin1");
  pdf += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  pdf += offsets
    .slice(1)
    .map((offset) => `${String(offset).padStart(10, "0")} 00000 n \n`)
    .join("");
  pdf += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R /Info 6 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return new TextEncoder().encode(pdf);
}
