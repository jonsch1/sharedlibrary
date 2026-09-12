import { BrieflyError } from "./errors.js";
import { AdapterRegistry } from "./adapters.js";
import { httpURL, saveInput, inputText } from "./input.js";
import { MCPConnection } from "./transport.js";
import type {
  AdapterRunnerRequest, AdapterRunnerStatus,
  BrieflyOptions, CapturePreview, ReadInput, ReadResult, SaveInput,
  SearchInput, SearchResult, SourceAdapter, WriteResult,
} from "./types.js";

export { startAdapterRunner } from "./runner.js";
export type { AdapterRunner, AdapterRunnerOptions, AdapterRunnerState } from "./runner.js";
export { BrieflyError } from "./errors.js";
export type {
  AdapterRunnerRequest, AdapterRunnerStatus,
  BrieflyOptions, CapturePreview, ReadInput, ReadResult, SaveInput,
  SearchInput, SearchResult, SourceAdapter, WriteResult,
} from "./types.js";

/** External resource capture through Briefly's app-owned MCP API. Construction does no I/O. */
export class Briefly {
  private readonly connection: MCPConnection;
  private readonly registry: AdapterRegistry;
  private closed = false;

  constructor(options: BrieflyOptions = {}) {
    this.registry = new AdapterRegistry(options.adapters ?? []);
    this.connection = new MCPConnection(options);
  }

  /** Extract with the first matching custom adapter, or let the app route the URL through its connected runner and native extraction. */
  async capture(url: string | URL): Promise<WriteResult> {
    const preview = await this.preview(url);
    return preview.kind === "custom"
      ? this.save(preview.document)
      : writeResult(await this.connection.call("capture", { url: preview.url }));
  }

  /** Runs custom extraction without connecting to Briefly. App previews only describe routing. */
  async preview(input: string | URL): Promise<CapturePreview> {
    this.assertOpen();
    return this.registry.preview(input);
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

  /** Runner registration and connection status. startAdapterRunner normally manages the lease. */
  async adapterRunner(request: AdapterRunnerRequest): Promise<AdapterRunnerStatus> {
    this.assertOpen();
    const result = responseObject(await this.connection.call("adapter_runner", { ...request }));
    if (typeof result.connected !== "boolean" || typeof result.adapterCount !== "number" ||
        !Number.isInteger(result.adapterCount) || result.adapterCount < 0 || result.adapterCount > 100) throw invalidResponse();
    return { connected: result.connected, adapterCount: result.adapterCount };
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
