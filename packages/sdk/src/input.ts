import { BrieflyError } from "./errors.js";
import type { SaveInput } from "./types.js";

export function httpURL(input: string | URL): string {
  const value = input instanceof URL ? input.href : input;
  if (typeof value !== "string" || value.trim().length > 2048 || /\s/.test(value.trim())) {
    throw new BrieflyError("invalid_input", "url must be an absolute HTTP(S) URL of at most 2,048 characters.");
  }
  try {
    const url = new URL(value.trim());
    if (!["http:", "https:"].includes(url.protocol) || !url.hostname || url.username || url.password || url.href.length > 2048) {
      throw new Error("Invalid URL.");
    }
    return url.href;
  } catch {
    throw new BrieflyError("invalid_input", "url must be an absolute HTTP(S) URL without embedded credentials.");
  }
}

export function saveInput(value: SaveInput): SaveInput {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new BrieflyError("invalid_input", "A document must contain title and content.");
  }
  const fields = new Set(["title", "content", "url", "concise", "detailed"]);
  if (Object.keys(value).some((key) => !fields.has(key))) {
    throw new BrieflyError("invalid_input", "Documents support title, content, url, concise, and detailed only.");
  }
  const document: SaveInput = {
    title: inputText(value.title, "title", 200),
    content: inputText(value.content, "content", 500_000),
  };
  if (value.url !== undefined) document.url = httpURL(value.url);
  for (const field of ["concise", "detailed"] as const) {
    if (value[field] !== undefined) {
      const text = inputText(value[field], field, field === "concise" ? 100_000 : 500_000, true);
      if (text.trim()) document[field] = text;
    }
  }
  return document;
}

export function inputText(value: unknown, name: string, maximum: number, allowEmpty = false): string {
  if (typeof value !== "string" || value.length > maximum || (!allowEmpty && !value.trim())) {
    throw new BrieflyError("invalid_input", `${name} must contain ${allowEmpty ? "0" : "1"}–${maximum.toLocaleString("en-US")} characters.`);
  }
  return value;
}

