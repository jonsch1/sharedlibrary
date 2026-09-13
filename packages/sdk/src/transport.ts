import { execFile } from "node:child_process";
import { constants } from "node:fs";
import { access } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import { promisify } from "node:util";
import { Client, SdkError, SdkErrorCode } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";
import { BrieflyError } from "./errors.js";
import type { BrieflyOptions } from "./types.js";

const execFileAsync = promisify(execFile);
const INITIALIZE_TIMEOUT_MS = 15_000;
const DEFAULT_REQUEST_TIMEOUT_MS = 300_000;

function closedError(): BrieflyError {
  return new BrieflyError("client_closed", "This Briefly client is closed. Create a new client to continue.");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function resolveHelperPath(explicitPath: string | undefined, signal: AbortSignal): Promise<string> {
  let helperPath = explicitPath;
  if (helperPath !== undefined && (typeof helperPath !== "string" || !isAbsolute(helperPath))) {
    throw new BrieflyError("invalid_input", "helperPath must be an absolute executable path.");
  }
  if (helperPath === undefined) {
    if (process.platform !== "darwin") {
      throw new BrieflyError(
        "unsupported_platform",
        "Automatic Briefly discovery requires macOS. Use Briefly on a Mac, or supply an absolute helperPath for development.",
      );
    }
    let appPath: string;
    try {
      const { stdout } = await execFileAsync("/usr/bin/osascript", [
        "-l", "JavaScript", "-e",
        `ObjC.import("AppKit");
         const id = "fyi.readbriefly.BrieflyNative";
         const running = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(id);
         let selected = null;
         let latest = -1;
         for (let index = 0; index < running.count; index++) {
           const app = running.objectAtIndex(index);
           const launched = app.launchDate.isNil() ? 0 : app.launchDate.timeIntervalSince1970;
           if (!app.bundleURL.isNil() && launched >= latest) { selected = app.bundleURL; latest = launched; }
         }
         const url = selected || $.NSWorkspace.sharedWorkspace.URLForApplicationWithBundleIdentifier(id);
         url.isNil() ? "" : ObjC.unwrap(url.path);`,
      ], { encoding: "utf8", timeout: INITIALIZE_TIMEOUT_MS, maxBuffer: 16_384, signal });
      appPath = stdout.trim();
    } catch (cause) {
      throw new BrieflyError(
        "app_not_found",
        "Could not locate Briefly. Install the macOS app or supply its absolute briefly-mcp helperPath.",
        { cause },
      );
    }
    if (!appPath || !isAbsolute(appPath)) {
      throw new BrieflyError(
        "app_not_found",
        "Briefly is not installed. Install the macOS app or supply its absolute briefly-mcp helperPath.",
      );
    }
    helperPath = join(appPath, "Contents", "Helpers", "BrieflyMCP.app", "Contents", "MacOS", "briefly-mcp");
  }
  try {
    await access(helperPath, constants.X_OK);
  } catch (cause) {
    throw new BrieflyError(
      "helper_not_found",
      "The briefly-mcp helper is missing or not executable. Reinstall Briefly or correct helperPath.",
      { cause },
    );
  }
  return helperPath;
}

/** Internal stdio transport. All production writes still go through the running app. */
export class MCPConnection {
  readonly #options: Pick<BrieflyOptions, "helperPath" | "requestTimeoutMs">;
  readonly #abort = new AbortController();
  #connection: Promise<Client> | undefined;
  #closing: Promise<void> | undefined;
  #closed = false;

  constructor(options: Pick<BrieflyOptions, "helperPath" | "requestTimeoutMs"> = {}) {
    if (options.requestTimeoutMs !== undefined &&
        (!Number.isInteger(options.requestTimeoutMs) || options.requestTimeoutMs <= 0 || options.requestTimeoutMs > 2_147_483_647)) {
      throw new BrieflyError("invalid_input", "requestTimeoutMs must be an integer between 1 and 2,147,483,647.");
    }
    this.#options = { ...options };
  }

  async #connect(): Promise<Client> {
    let transport: StdioClientTransport | undefined;
    let client: Client | undefined;
    try {
      const helperPath = await resolveHelperPath(this.#options.helperPath, this.#abort.signal);
      if (this.#closed) throw closedError();
      transport = new StdioClientTransport({ command: helperPath, stderr: "ignore" });
      client = new Client({ name: "readbriefly-sdk", version: "0.1.0" }, {
        capabilities: {},
        versionNegotiation: { mode: "legacy" },
      });
      await client.connect(transport, {
        timeout: INITIALIZE_TIMEOUT_MS,
        signal: this.#abort.signal,
      });
      if (this.#closed) throw closedError();
      return client;
    } catch (cause) {
      await client?.close().catch(() => {});
      await transport?.close().catch(() => {});
      if (this.#closed) throw closedError();
      if (cause instanceof BrieflyError) throw cause;
      throw new BrieflyError(
        "connection_failed",
        "Could not connect to the Briefly helper. Check that Briefly is installed correctly and that helperPath points to its executable.",
        { cause },
      );
    }
  }

  async call(name: string, args: Record<string, unknown>): Promise<unknown> {
    if (this.#closed) throw closedError();
    const client = await (this.#connection ??= this.#connect());
    if (this.#closed) throw closedError();
    let result;
    try {
      result = await client.callTool({ name, arguments: args }, {
        timeout: this.#options.requestTimeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS,
        signal: this.#abort.signal,
      });
    } catch (cause) {
      if (this.#closed) throw closedError();
      if (cause instanceof SdkError && cause.code === SdkErrorCode.InvalidResult) {
        throw new BrieflyError("invalid_response", "Briefly returned an invalid MCP result.", { cause });
      }
      const timedOut = cause instanceof SdkError && cause.code === SdkErrorCode.RequestTimeout;
      throw new BrieflyError(
        timedOut ? "request_timeout" : "request_failed",
        timedOut
          ? "Briefly did not respond before the request deadline. A write may have completed; check your library before retrying."
          : "The Briefly request failed. A write may have completed; check your library before retrying.",
        { cause },
      );
    }

    const content = result.content;
    const item = content[0];
    if (content.length !== 1 || item?.type !== "text") {
      throw new BrieflyError("invalid_response", "Briefly returned an unexpected response. Update the app and SDK together.");
    }
    let value: unknown;
    try {
      value = JSON.parse(item.text);
    } catch (cause) {
      throw new BrieflyError("invalid_response", "Briefly returned invalid JSON.", { cause });
    }
    if (result.isError) {
      const error = isRecord(value) ? value.error : undefined;
      if (!isRecord(error) || typeof error.code !== "string" || typeof error.message !== "string") {
        throw new BrieflyError("invalid_response", "Briefly returned an invalid error response.");
      }
      throw new BrieflyError(error.code, error.message);
    }
    return value;
  }

  async close(): Promise<void> {
    this.#closed = true;
    this.#abort.abort();
    return this.#closing ??= (async () => {
      const client = await this.#connection?.catch(() => undefined);
      await client?.close();
    })();
  }
}
