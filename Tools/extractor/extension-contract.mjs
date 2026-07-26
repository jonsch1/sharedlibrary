import { readFile, readdir, realpath } from "node:fs/promises";
import { dirname, relative, resolve, sep } from "node:path";

export const INPUT_API_VERSION = 1;
export const DEFAULT_EXTENSION_ENTRY = "input.mjs";

const INPUT_ID_PATTERN = /^[a-z0-9]+(?:-[a-z0-9]+)*$/u;
const SOURCE_TYPE_PATTERN = /^[a-z0-9]+(?:-[a-z0-9]+)*$/u;

export async function discoverWorkspaceInputs(directory, { onDiagnostic } = {}) {
  if (typeof directory !== "string" || !directory.trim()) return [];

  let entries;
  try {
    entries = await readdir(directory, { withFileTypes: true });
  } catch (error) {
    if (error?.code === "ENOENT") return [];
    throw error;
  }

  const inputs = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name.startsWith(".")) continue;
    const packageDirectory = resolve(directory, entry.name);
    const manifestPath = resolve(packageDirectory, "input.json");
    try {
      inputs.push(await readWorkspaceInputManifest(manifestPath));
    } catch (error) {
      onDiagnostic?.({
        kind: "extension-invalid",
        package: entry.name,
        reason: error instanceof Error ? error.message : String(error)
      });
    }
  }

  return inputs.sort(
    (left, right) =>
      right.priority - left.priority || left.id.localeCompare(right.id)
  );
}

export async function readWorkspaceInputManifest(manifestPath) {
  let value;
  try {
    value = JSON.parse(await readFile(manifestPath, "utf8"));
  } catch (error) {
    throw new Error(
      `Could not read ${manifestPath}: ${error instanceof Error ? error.message : String(error)}`
    );
  }

  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("input.json must contain a JSON object.");
  }
  if (value.apiVersion !== INPUT_API_VERSION) {
    throw new Error(
      `Unsupported input apiVersion ${JSON.stringify(value.apiVersion)}; expected ${INPUT_API_VERSION}.`
    );
  }
  const id = requiredIdentifier(value.id, "id", INPUT_ID_PATTERN);
  const sourceType = requiredIdentifier(
    value.sourceType,
    "sourceType",
    SOURCE_TYPE_PATTERN
  );
  const match = validateMatch(value.match);
  const fallback = value.fallback ?? "builtin";
  if (fallback !== "builtin" && fallback !== "none") {
    throw new Error('fallback must be either "builtin" or "none".');
  }
  const priority = value.priority ?? 100;
  if (!Number.isInteger(priority) || priority < -1000 || priority > 1000) {
    throw new Error("priority must be an integer between -1000 and 1000.");
  }
  const entry = value.entry ?? DEFAULT_EXTENSION_ENTRY;
  if (typeof entry !== "string" || !entry.trim()) {
    throw new Error("entry must be a non-empty relative path.");
  }

  const packageDirectory = dirname(manifestPath);
  const canonicalPackageDirectory = await realpath(packageDirectory);
  const entryPath = await realpath(resolve(packageDirectory, entry));
  if (!isInside(canonicalPackageDirectory, entryPath)) {
    throw new Error("entry must resolve inside the input package directory.");
  }

  return {
    apiVersion: INPUT_API_VERSION,
    entryPath,
    fallback,
    id,
    manifestPath,
    match,
    packageDirectory: canonicalPackageDirectory,
    priority,
    sourceType
  };
}

export function matchesWorkspaceInput(input, rawURL) {
  let url;
  try {
    url = new URL(rawURL);
  } catch {
    return false;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return false;

  const hostname = url.hostname.toLowerCase().replace(/\.$/u, "");
  const hostMatches = input.match.hosts.some((pattern) =>
    matchesHost(pattern, hostname)
  );
  if (!hostMatches) return false;

  return (
    input.match.pathPrefixes.length === 0 ||
    input.match.pathPrefixes.some((prefix) => url.pathname.startsWith(prefix))
  );
}

function validateMatch(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("match must be an object.");
  }
  if (!Array.isArray(value.hosts) || value.hosts.length === 0) {
    throw new Error("match.hosts must be a non-empty array.");
  }
  const hosts = [...new Set(value.hosts.map(validateHostPattern))];
  const rawPrefixes = value.pathPrefixes ?? [];
  if (!Array.isArray(rawPrefixes)) {
    throw new Error("match.pathPrefixes must be an array when provided.");
  }
  const pathPrefixes = [
    ...new Set(
      rawPrefixes.map((prefix) => {
        if (
          typeof prefix !== "string" ||
          !prefix.startsWith("/") ||
          prefix.includes("?") ||
          prefix.includes("#")
        ) {
          throw new Error(
            "Every path prefix must begin with / and exclude query strings and fragments."
          );
        }
        return prefix;
      })
    )
  ];
  return { hosts, pathPrefixes };
}

function validateHostPattern(value) {
  if (typeof value !== "string" || !value.trim()) {
    throw new Error("Every host pattern must be a non-empty string.");
  }
  const normalized = value.trim().toLowerCase().replace(/\.$/u, "");
  const hostname = normalized.startsWith("*.") ? normalized.slice(2) : normalized;
  if (
    !hostname.includes(".") ||
    !/^[a-z0-9.-]+$/u.test(hostname) ||
    hostname.startsWith(".") ||
    hostname.endsWith(".") ||
    hostname.includes("..")
  ) {
    throw new Error(`Invalid host pattern: ${value}`);
  }
  return normalized.startsWith("*.") ? `*.${hostname}` : hostname;
}

function matchesHost(pattern, hostname) {
  if (!pattern.startsWith("*.")) return hostname === pattern;
  const suffix = pattern.slice(1);
  return hostname.endsWith(suffix) && hostname.length > suffix.length;
}

function requiredIdentifier(value, label, pattern) {
  if (typeof value !== "string" || !pattern.test(value)) {
    throw new Error(
      `${label} must use lowercase letters, numbers, and single hyphens.`
    );
  }
  return value;
}

function isInside(directory, candidate) {
  const child = relative(directory, candidate);
  return child === "" || (!child.startsWith(`..${sep}`) && child !== "..");
}
