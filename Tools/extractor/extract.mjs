#!/usr/bin/env node
import { extractLink } from "./inputs/registry.mjs";

const { extensionsDirectory, url } = parseArguments(process.argv.slice(2));

if (!url) {
  console.error("Usage: node extract.mjs [--extensions <directory>] <url>");
  process.exit(2);
}

const includeTranscriptTimestamps =
  parseBoolean(
    process.env.BRIEFLY_TRANSCRIPT_TIMESTAMPS ??
      process.env.SHARED_LIBRARY_TRANSCRIPT_TIMESTAMPS
  ) ?? false;

try {
  const extracted = await extractLink(url, {
    extensionsDirectory,
    includeTranscriptTimestamps,
    onProgress(event) {
      if (event.kind === "fetch-start") {
        console.error(`fetching ${event.url}`);
      } else if (event.kind === "input-fallback") {
        console.error(
          `${event.from} extraction failed; using ${event.to}: ${event.reason}`
        );
      } else if (event.kind === "extension-invalid") {
        console.error(
          `ignoring invalid workspace input ${event.package}: ${event.reason}`
        );
      }
    }
  });
  process.stdout.write(`${JSON.stringify(extracted)}\n`);
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}

function parseArguments(values) {
  let extensionsDirectory = null;
  let url = null;
  for (let index = 0; index < values.length; index += 1) {
    const value = values[index];
    if (value === "--extensions") {
      extensionsDirectory = values[index + 1]?.trim() || null;
      index += 1;
    } else if (!url) {
      url = value?.trim() || null;
    } else {
      throw new Error(`Unexpected extractor argument: ${value}`);
    }
  }
  return { extensionsDirectory, url };
}

function parseBoolean(value) {
  if (typeof value !== "string") return null;
  const normalized = value.trim().toLowerCase();
  if (["1", "true", "yes", "on"].includes(normalized)) return true;
  if (["0", "false", "no", "off"].includes(normalized)) return false;
  return null;
}
