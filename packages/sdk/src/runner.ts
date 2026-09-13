import { randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { createServer, type IncomingMessage } from "node:http";
import { AdapterRegistry } from "./adapters.js";
import { BrieflyError } from "./errors.js";
import { MCPConnection } from "./transport.js";
import type { BrieflyOptions, SourceAdapter } from "./types.js";
import type { Briefly } from "./index.js";

export type AdapterRunnerState = { connected: boolean; adapterCount: number; error?: string };
export interface AdapterRunnerOptions extends Pick<BrieflyOptions, "helperPath"> {
  adapters: readonly SourceAdapter[];
  /** Reuse an existing client; its owner remains responsible for closing it. */
  client?: Briefly;
  onStatus?: (state: AdapterRunnerState) => void;
}
export interface AdapterRunner {
  readonly state: AdapterRunnerState;
  /** Reconnect immediately, for example after opening Briefly. Automatic renewal runs every 15s. */
  refresh(): Promise<AdapterRunnerState>;
  close(): Promise<void>;
}

/** Serve source data to the running app. This process never saves extracted documents itself. */
export async function startAdapterRunner(options: AdapterRunnerOptions): Promise<AdapterRunner> {
  const registry = new AdapterRegistry(options.adapters);
  if (registry.adapters.length < 1 || registry.adapters.length > 100) {
    throw new BrieflyError("invalid_input", "A runner needs 1–100 adapters.");
  }
  if (options.client && options.helperPath) throw new BrieflyError("invalid_input", "Use either client or helperPath.");
  const id = randomUUID();
  const token = randomBytes(32).toString("hex");
  const authorization = Buffer.from(`Bearer ${token}`);
  let connection = new MCPConnection({ ...options, requestTimeoutMs: 3_000 });
  let closed = false;
  let active = 0;
  let state: AdapterRunnerState = { connected: false, adapterCount: registry.adapters.length };
  let refreshing: Promise<AdapterRunnerState> | undefined;
  let closing: Promise<void> | undefined;

  const server = createServer(async (request, response) => {
    const received = Buffer.from(request.headers.authorization ?? "");
    const address = server.address();
    const expectedHost = address && typeof address !== "string" ? `127.0.0.1:${address.port}` : "";
    if (closed || request.headers.host !== expectedHost || request.headers.origin !== undefined ||
        received.length !== authorization.length || !timingSafeEqual(received, authorization)) {
      response.writeHead(403).end();
      return;
    }
    if (request.method !== "POST" || !["/resolve", "/extract"].includes(request.url ?? "")) {
      response.writeHead(404).end();
      return;
    }
    if (active >= 4) { response.writeHead(503).end(); return; }
    active++;
    try {
      const body = await readRequest(request);
      if (typeof body.url !== "string") throw new Error("Missing URL.");
      let result: unknown;
      if (request.url === "/resolve") {
        const { matched, adapterId } = registry.resolve(body.url);
        result = { matched, adapterId };
      } else {
        if (typeof body.adapterId !== "string") throw new Error("Missing adapter id.");
        result = { document: await registry.extract(body.adapterId, body.url) };
      }
      const json = JSON.stringify(result);
      if (Buffer.byteLength(json) > 2_000_000) throw new Error("Extracted document is too large.");
      response.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" }).end(json);
    } catch {
      if (!response.destroyed && !response.headersSent) {
        response.writeHead(422, { "content-type": "application/json" }).end(JSON.stringify({
          error: { code: "adapter_failed", message: "Custom handling failed. Inspect the adapter with preview before retrying." },
        }));
      }
    } finally {
      active--;
    }
  });
  server.requestTimeout = 5_000;
  server.headersTimeout = 5_000;
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => { server.off("error", reject); resolve(); });
  });
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("Could not start adapter runner.");
  const port = address.port;

  function notify(next: AdapterRunnerState): void {
    const changed = JSON.stringify(state) !== JSON.stringify(next);
    state = next;
    if (changed) {
      try { options.onStatus?.({ ...state }); } catch { /* Reporting cannot break renewal. */ }
    }
  }

  async function renew(): Promise<AdapterRunnerState> {
    if (closed) return { ...state };
    try {
      const request = {
        action: "connect" as const, id, port, token,
        adapterIDs: registry.adapters.map((adapter) => adapter.id),
      };
      if (options.client) await options.client.adapterRunner(request);
      else await connection.call("adapter_runner", request);
      if (!closed) notify({ connected: true, adapterCount: registry.adapters.length });
    } catch (error) {
      if (!closed) {
        notify({ connected: false, adapterCount: registry.adapters.length,
          error: error instanceof BrieflyError ? error.code : "connection_failed" });
        // A helper or app can be restarted while the runner stays alive. Registration is safe
        // to retry (same runner ID); captures and saves are never retried here.
        if (!options.client) {
          await connection.close().catch(() => {});
          connection = new MCPConnection({ ...options, requestTimeoutMs: 3_000 });
        }
      }
    }
    return { ...state };
  }

  function refresh(): Promise<AdapterRunnerState> {
    return refreshing ??= renew().finally(() => { refreshing = undefined; });
  }
  const timer = setInterval(() => { void refresh(); }, 15_000);
  await refresh();
  return {
    get state() { return { ...state }; },
    refresh,
    close() {
      return closing ??= (async () => {
        closed = true;
        clearInterval(timer);
        await refreshing;
        const request = { action: "disconnect" as const, id };
        if (options.client) await options.client.adapterRunner(request).catch(() => {});
        else await connection.call("adapter_runner", request).catch(() => {});
        await connection.close();
        server.closeAllConnections();
        await new Promise<void>((resolve) => server.close(() => resolve()));
        notify({ connected: false, adapterCount: registry.adapters.length });
      })();
    },
  };
}

async function readRequest(request: IncomingMessage): Promise<Record<string, unknown>> {
  let size = 0;
  const chunks: Buffer[] = [];
  for await (const chunk of request) {
    const bytes = Buffer.from(chunk);
    size += bytes.length;
    if (size > 16_000) throw new Error("Request too large.");
    chunks.push(bytes);
  }
  const value: unknown = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid request.");
  return value as Record<string, unknown>;
}
