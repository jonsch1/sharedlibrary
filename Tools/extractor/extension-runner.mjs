#!/usr/bin/env node
import { pathToFileURL } from "node:url";

import { extractGenericHTMLFromSource } from "./inputs/generic-html.mjs";
import { fetchText as fetchBufferedText } from "./inputs/http.mjs";

const [, , entryPath, rawURL, serializedOptions = "{}"] = process.argv;

if (!entryPath || !rawURL) {
  console.error("Usage: extension-runner.mjs <entry> <url> [options-json]");
  process.exit(2);
}

const nativeFetch = globalThis.fetch.bind(globalThis);
const options = parseOptions(serializedOptions);
const controller = new AbortController();
const deadline = setTimeout(() => controller.abort(), 115_000);

redirectConsoleToStandardError();
globalThis.fetch = extensionFetch;

try {
  const module = await import(pathToFileURL(entryPath).href);
  const input = module.default;
  if (!input || typeof input !== "object" || typeof input.extract !== "function") {
    throw new Error(
      "input.mjs must default-export an object with an extract(request, briefly) function."
    );
  }

  const request = Object.freeze({
    options: Object.freeze(options),
    signal: controller.signal,
    url: new URL(rawURL)
  });
  const briefly = Object.freeze({
    apiVersion: 1,
    extractHTML({ html, url = rawURL } = {}) {
      if (typeof html !== "string") {
        throw new Error("extractHTML requires an html string.");
      }
      return extractGenericHTMLFromSource(String(url), html);
    },
    fetch: extensionFetch,
    async fetchText(url, init) {
      return (await extensionFetch(url, init)).text();
    },
    log(message) {
      console.error(String(message));
    }
  });

  const result = await input.extract(request, briefly);
  process.stdout.write(`${JSON.stringify(result)}\n`);
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
} finally {
  clearTimeout(deadline);
}

async function extensionFetch(input, init = {}) {
  const url =
    input instanceof URL
      ? input.toString()
      : typeof input === "string"
        ? input
        : input?.url;
  if (typeof url !== "string") {
    throw new Error("fetch requires an HTTP(S) URL.");
  }
  const parsed = new URL(url);
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new Error("Extension fetch supports only HTTP(S) URLs.");
  }
  if (controller.signal.aborted) {
    throw new Error("The extension extraction deadline was exceeded.");
  }

  const fetched = await fetchBufferedText(parsed.toString(), {
    body: init.body,
    fetchImpl: nativeFetch,
    headers: headersObject(init.headers),
    method: init.method,
    onProgress: null,
    timeoutMilliseconds: Math.min(
      positiveInteger(init.timeoutMilliseconds) ?? 30_000,
      120_000
    )
  });
  return bufferedResponse(fetched);
}

function bufferedResponse(fetched) {
  const headers = new Headers(fetched.headers);
  return Object.freeze({
    headers,
    ok: fetched.status >= 200 && fetched.status < 300,
    redirected: fetched.finalURL !== fetched.requestedURL,
    status: fetched.status,
    statusText: fetched.statusText,
    url: fetched.finalURL,
    async json() {
      return JSON.parse(fetched.text);
    },
    async text() {
      return fetched.text;
    }
  });
}

function headersObject(value) {
  if (!value) return {};
  if (value instanceof Headers) return Object.fromEntries(value.entries());
  if (Array.isArray(value)) return Object.fromEntries(value);
  return { ...value };
}

function parseOptions(value) {
  try {
    const parsed = JSON.parse(value);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? parsed
      : {};
  } catch {
    return {};
  }
}

function positiveInteger(value) {
  return Number.isInteger(value) && value > 0 ? value : null;
}

function redirectConsoleToStandardError() {
  const write = (...values) => {
    process.stderr.write(`${values.map(String).join(" ")}\n`);
  };
  console.log = write;
  console.info = write;
  console.debug = write;
  console.warn = write;
}
