import { BrieflyError } from "./errors.js";
import { MCPConnection } from "./transport.js";
import type {
  BrieflyOptions, CapturePreview, ReadInput, ReadResult, SaveInput,
  SearchInput, SearchResult, SourceAdapter, WriteResult,
} from "./types.js";

export { BrieflyError } from "./errors.js";
export type {
  BrieflyOptions, CapturePreview, ReadInput, ReadResult, SaveInput,
  SearchInput, SearchResult, SourceAdapter, WriteResult,
} from "./types.js";

/** External resource capture through Briefly's app-owned MCP API. Construction does no I/O. */
export class Briefly {
  private readonly connection: MCPConnection;
  private readonly adapters: readonly SourceAdapter[];
  private closed = false;

  constructor(options: BrieflyOptions = {}) {
    const ids = new Set<string>();
    this.adapters = [...(options.adapters ?? [])];
    for (const adapter of this.adapters) {
      if (!adapter || typeof adapter.id !== "string" || !adapter.id.trim() ||
          ids.has(adapter.id) || typeof adapter.matches !== "function" ||
          typeof adapter.extract !== "function") {
        throw new BrieflyError("invalid_input", "Adapters need a unique nonempty id, matches, and extract.");
      }
      ids.add(adapter.id);
    }
    this.connection = new MCPConnection(options);
  }

  /** Extract with the first matching custom adapter, or ask Briefly to ingest the URL. */
  async capture(url: string | URL): Promise<WriteResult> {
    const preview = await this.preview(url);
    return preview.kind === "custom"
      ? this.save(preview.document)
      : this.ingest(preview.url);
  }

  /** Runs custom extraction without connecting to Briefly. Native previews only describe routing. */
  async preview(input: string | URL): Promise<CapturePreview> {
    this.assertOpen();
    const url = httpURL(input);
    for (const adapter of this.adapters) {
      let matches: boolean;
      try {
        matches = adapter.matches(new URL(url));
        if (typeof matches !== "boolean") throw new Error("matches must return a boolean.");
      } catch (cause) {
        throw new BrieflyError("adapter_failed", `Adapter ${adapter.id} could not match this resource.`, { cause });
      }
      if (!matches) continue;
      try {
        const extracted = await adapter.extract(new URL(url));
        const document = saveInput(extracted);
        document.url ??= url;
        return { kind: "custom", adapterId: adapter.id, url, document };
      } catch (cause) {
        throw new BrieflyError("adapter_failed", `Adapter ${adapter.id} could not extract a valid document.`, { cause });
      }
    }
    return { kind: "native", url };
  }

  /** Explicit native ingestion, bypassing custom adapters. */
  async ingest(url: string | URL): Promise<WriteResult> {
    this.assertOpen();
    return writeResult(await this.connection.call("ingest", { url: httpURL(url) }));
  }

  /** Save supplied content. A repeated canonical URL updates its existing document. */
  async save(document: SaveInput): Promise<WriteResult> {
    this.assertOpen();
    return writeResult(await this.connection.call("save", { ...saveInput(document) }));
  }

  async search(input: SearchInput = {}): Promise<SearchResult> {
    this.assertOpen();
    const args: Record<string, unknown> = {};
    if (input.q !== undefined) args.q = inputText(input.q, "q", 500, true);
    if (input.limit !== undefined) {
      if (!Number.isInteger(input.limit) || input.limit < 1 || input.limit > 10) {
        throw new BrieflyError("invalid_input", "limit must be between 1 and 10.");
      }
      args.limit = input.limit;
    }
    const result = responseObject(await this.connection.call("search", args));
    if (!Array.isArray(result.items)) throw invalidResponse();
    const items = result.items.map((value) => {
      const item = responseObject(value);
      if (!nonempty(item.id) || typeof item.title !== "string" ||
          (item.snippet !== undefined && typeof item.snippet !== "string")) throw invalidResponse();
      return {
        id: item.id, title: item.title,
        ...(typeof item.snippet === "string" ? { snippet: item.snippet } : {}),
      };
    });
    return { items };
  }

  async read(input: ReadInput): Promise<ReadResult> {
    this.assertOpen();
    if (!nonempty(input.id)) throw new BrieflyError("invalid_input", "id must be a nonempty string.");
    const args: Record<string, unknown> = { id: input.id };
    if (input.detail !== undefined) {
      if (typeof input.detail !== "boolean") throw new BrieflyError("invalid_input", "detail must be a boolean.");
      args.detail = input.detail;
    }
    if (input.cursor !== undefined) {
      if (!Number.isSafeInteger(input.cursor) || input.cursor < 0) {
        throw new BrieflyError("invalid_input", "cursor must be a nonnegative integer.");
      }
      args.cursor = input.cursor;
    }
    const result = responseObject(await this.connection.call("read", args));
    if (!nonempty(result.id) || typeof result.title !== "string") throw invalidResponse();
    const identity = { id: result.id, title: result.title };
    if (typeof result.text === "string") {
      if (result.next === undefined) return { ...identity, text: result.text };
      if (typeof result.next !== "number" || !Number.isSafeInteger(result.next) || result.next < 0) {
        throw invalidResponse();
      }
      return { ...identity, text: result.text, next: result.next };
    }
    if (result.status === "processing") return { ...identity, status: "processing" };
    throw invalidResponse();
  }

  /** Release the MCP helper process. Does not close the Briefly app. */
  async close(): Promise<void> {
    this.closed = true;
    await this.connection.close();
  }

  private assertOpen(): void {
    if (this.closed) throw new BrieflyError("client_closed", "This Briefly client is closed. Create a new client.");
  }
}

function httpURL(input: string | URL): string {
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

function saveInput(value: SaveInput): SaveInput {
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

function inputText(value: unknown, name: string, maximum: number, allowEmpty = false): string {
  if (typeof value !== "string" || value.length > maximum || (!allowEmpty && !value.trim())) {
    throw new BrieflyError("invalid_input", `${name} must contain ${allowEmpty ? "0" : "1"}–${maximum.toLocaleString("en-US")} characters.`);
  }
  return value;
}

function writeResult(value: unknown): WriteResult {
  const result = responseObject(value);
  if (!nonempty(result.id) || (result.status !== "ready" && result.status !== "processing")) throw invalidResponse();
  return { id: result.id, status: result.status };
}

function responseObject(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw invalidResponse();
  return value as Record<string, unknown>;
}

function nonempty(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function invalidResponse(): BrieflyError {
  return new BrieflyError("invalid_response", "Briefly returned an unexpected result.");
}
