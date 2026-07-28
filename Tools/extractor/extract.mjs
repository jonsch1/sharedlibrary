#!/usr/bin/env node
import { extractLink } from "./inputs/registry.mjs";
import { scrapeWithFirecrawl } from "./inputs/firecrawl.mjs";
import { extractPDFFile } from "./inputs/pdf.mjs";
import {
  downloadMediaAudio,
  transcribeMedia
} from "./inputs/transcription.mjs";

const { extensionsDirectory, file, url } = parseArguments(process.argv.slice(2));

if (!url && !file) {
  console.error(
    "Usage: node extract.mjs [--extensions <directory>] <url> | --file <pdf>"
  );
  process.exit(2);
}

const includeTranscriptTimestamps =
  parseBoolean(
    process.env.BRIEFLY_TRANSCRIPT_TIMESTAMPS ??
      process.env.SHARED_LIBRARY_TRANSCRIPT_TIMESTAMPS
  ) ?? false;
const mediaOutputDirectory =
  process.env.BRIEFLY_MEDIA_OUTPUT_DIRECTORY || undefined;
const saveCapturedAudio =
  parseBoolean(process.env.BRIEFLY_SAVE_CAPTURED_AUDIO) ?? false;

try {
  const extracted = file
    ? await extractPDFFile(file)
    : await extractLink(url, {
        extensionsDirectory,
        firecrawlFallback:
          process.env.BRIEFLY_FIRECRAWL_ENDPOINT &&
          process.env.BRIEFLY_FIRECRAWL_TOKEN
          ? (sourceURL) =>
              scrapeWithFirecrawl(sourceURL, {
                endpoint: process.env.BRIEFLY_FIRECRAWL_ENDPOINT,
                token: process.env.BRIEFLY_FIRECRAWL_TOKEN
              })
          : null,
        includeTranscriptTimestamps,
        transcribeMedia:
          process.env.BRIEFLY_TRANSCRIPT_ENDPOINT &&
          process.env.BRIEFLY_TRANSCRIPT_TOKEN
            ? (mediaURL) =>
                transcribeMedia(mediaURL, {
                  endpoint: process.env.BRIEFLY_TRANSCRIPT_ENDPOINT,
                  includeTranscriptTimestamps,
                  mediaOutputDirectory,
                  token: process.env.BRIEFLY_TRANSCRIPT_TOKEN
                })
            : null,
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
  if (
    saveCapturedAudio &&
    extracted?.extractor === "youtube" &&
    mediaOutputDirectory
  ) {
    try {
      await downloadMediaAudio(extracted.url, mediaOutputDirectory);
    } catch (error) {
      console.error(
        `audio retention failed: ${error instanceof Error ? error.message : String(error)}`
      );
    }
  }
  process.stdout.write(`${JSON.stringify(extracted)}\n`);
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}

function parseArguments(values) {
  let extensionsDirectory = null;
  let file = null;
  let url = null;
  for (let index = 0; index < values.length; index += 1) {
    const value = values[index];
    if (value === "--extensions") {
      extensionsDirectory = values[index + 1]?.trim() || null;
      index += 1;
    } else if (value === "--file") {
      file = values[index + 1]?.trim() || null;
      index += 1;
    } else if (!url) {
      url = value?.trim() || null;
    } else {
      throw new Error(`Unexpected extractor argument: ${value}`);
    }
  }
  if (file && url) throw new Error("Choose a URL or a PDF file, not both.");
  return { extensionsDirectory, file, url };
}

function parseBoolean(value) {
  if (typeof value !== "string") return null;
  const normalized = value.trim().toLowerCase();
  if (["1", "true", "yes", "on"].includes(normalized)) return true;
  if (["0", "false", "no", "off"].includes(normalized)) return false;
  return null;
}
