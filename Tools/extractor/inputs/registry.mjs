import { spawn } from "node:child_process";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

import {
  discoverWorkspaceInputs,
  matchesWorkspaceInput
} from "../extension-contract.mjs";
import { arxivInput } from "./arxiv.mjs";
import { blueskyInput } from "./bluesky.mjs";
import { genericHTMLInput } from "./generic-html.mjs";
import { threadsInput } from "./threads.mjs";
import { xInput } from "./x.mjs";
import { youtubeInput } from "./youtube.mjs";

const specializedInputs = [
  arxivInput,
  youtubeInput,
  xInput,
  blueskyInput,
  threadsInput
];
const extensionRunnerPath = fileURLToPath(
  new URL("../extension-runner.mjs", import.meta.url)
);
const extractorDirectory = dirname(extensionRunnerPath);
const extensionTimeoutMilliseconds = 120_000;
const maximumExtensionOutputBytes = 40_000_000;

export function selectInput(rawUrl) {
  return (
    specializedInputs.find((input) => input.matches(rawUrl)) ??
    (genericHTMLInput.matches(rawUrl) ? genericHTMLInput : null)
  );
}

export async function extractLink(rawUrl, context = {}) {
  const workspaceInput = await selectWorkspaceInput(rawUrl, context);
  if (workspaceInput) {
    try {
      const result = await runWorkspaceInput(workspaceInput, rawUrl, context);
      return normalizeResult(result, workspaceInput, rawUrl);
    } catch (error) {
      const message = extensionFailureMessage(
        workspaceInput,
        "execution",
        error
      );
      if (workspaceInput.fallback === "none") throw new Error(message);
      context.onProgress?.({
        kind: "input-fallback",
        from: workspaceInput.id,
        to: "builtin",
        reason: message
      });
    }
  }

  const input = selectInput(rawUrl);
  if (!input) throw new Error("Only HTTP(S) links are supported.");

  try {
    return normalizeResult(await input.extract(rawUrl, context), input, rawUrl);
  } catch (error) {
    if (!input.fallbackToGeneric || input === genericHTMLInput) throw error;
    context.onProgress?.({
      kind: "input-fallback",
      from: input.id,
      to: genericHTMLInput.id,
      reason: error instanceof Error ? error.message : String(error)
    });
    return normalizeResult(
      await genericHTMLInput.extract(rawUrl, context),
      genericHTMLInput,
      rawUrl
    );
  }
}

async function selectWorkspaceInput(rawUrl, context) {
  const inputs = await discoverWorkspaceInputs(context.extensionsDirectory, {
    onDiagnostic: (event) => context.onProgress?.(event)
  });
  return inputs.find((input) => matchesWorkspaceInput(input, rawUrl)) ?? null;
}

async function runWorkspaceInput(input, rawUrl, context) {
  return new Promise((resolve, reject) => {
    const permissionArguments = [
      "--permission",
      `--allow-fs-read=${extractorDirectory}`,
      `--allow-fs-read=${input.packageDirectory}`
    ];
    const child = spawn(
      process.execPath,
      [
        ...permissionArguments,
        extensionRunnerPath,
        input.entryPath,
        rawUrl,
        JSON.stringify({
          transcriptTimestamps:
            context.includeTranscriptTimestamps === true
        })
      ],
      {
        cwd: input.packageDirectory,
        env: extensionEnvironment(input.id),
        stdio: ["ignore", "pipe", "pipe"]
      }
    );
    let output = "";
    let errors = "";
    let outputTooLarge = false;
    const timeout = setTimeout(() => {
      child.kill();
      reject(new Error("The extension exceeded its 120-second deadline."));
    }, extensionTimeoutMilliseconds);

    child.stdout.on("data", (chunk) => {
      output += String(chunk);
      if (Buffer.byteLength(output, "utf8") <= maximumExtensionOutputBytes) return;
      outputTooLarge = true;
      child.kill();
    });
    child.stderr.on("data", (chunk) => {
      errors += String(chunk);
      if (errors.length > 1_000_000) errors = errors.slice(-1_000_000);
    });
    child.on("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
    child.on("close", (code) => {
      clearTimeout(timeout);
      if (outputTooLarge) {
        reject(new Error("The extension result was too large."));
        return;
      }
      if (code !== 0) {
        reject(
          new Error(
            lastDiagnostic(errors) ||
              `The extension process exited with status ${code}.`
          )
        );
        return;
      }
      try {
        resolve(JSON.parse(output));
      } catch {
        reject(new Error("The extension returned invalid JSON."));
      }
    });
  });
}

function normalizeResult(result, input, requestedURL) {
  if (!result || typeof result !== "object") {
    throw new Error(`${input.id} did not return an extraction result.`);
  }
  const content = typeof result.content === "string" ? result.content.trim() : "";
  if (!content) {
    throw new Error(`${input.id} did not return readable content.`);
  }
  const url =
    typeof result.sourceURL === "string" && result.sourceURL.trim()
      ? result.sourceURL.trim()
      : typeof result.url === "string" && result.url.trim()
        ? result.url.trim()
        : requestedURL;
  let parsedURL;
  try {
    parsedURL = new URL(url);
  } catch {
    throw new Error(`${input.id} returned an invalid sourceURL.`);
  }
  if (parsedURL.protocol !== "http:" && parsedURL.protocol !== "https:") {
    throw new Error(`${input.id} returned a non-HTTP(S) sourceURL.`);
  }
  if (parsedURL.username || parsedURL.password) {
    throw new Error(`${input.id} returned a sourceURL containing credentials.`);
  }
  const routedInput =
    input === genericHTMLInput &&
    typeof result.extractor === "string" &&
    typeof result.sourceType === "string"
      ? { id: result.extractor, sourceType: result.sourceType }
      : input;
  return {
    ...result,
    url: parsedURL.toString(),
    title:
      typeof result.title === "string" && result.title.trim()
        ? result.title.trim()
        : null,
    description:
      typeof result.description === "string" && result.description.trim()
        ? result.description.trim()
        : null,
    siteName:
      typeof result.siteName === "string" && result.siteName.trim()
        ? result.siteName.trim()
        : null,
    content,
    extractor: routedInput.id,
    sourceType: routedInput.sourceType,
    totalCharacters: content.length,
    wordCount: content.split(/\s+/u).filter(Boolean).length
  };
}

function extensionEnvironment(inputID) {
  const environment = {
    BRIEFLY_INPUT_ID: inputID,
    ELECTRON_RUN_AS_NODE: "1"
  };
  for (const key of [
    "LANG",
    "LC_ALL",
    "TZ",
    "SYSTEMROOT",
    "WINDIR",
    "COMSPEC"
  ]) {
    if (process.env[key]) environment[key] = process.env[key];
  }
  return environment;
}

function extensionFailureMessage(input, phase, error) {
  const reason = error instanceof Error ? error.message : String(error);
  return `Workspace input "${input.id}" failed during ${phase}: ${reason}`;
}

function lastDiagnostic(value) {
  return (
    value
      .trim()
      .split(/\r?\n/u)
      .filter(Boolean)
      .at(-1) ?? ""
  );
}
