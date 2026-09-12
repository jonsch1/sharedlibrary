import { BrieflyError } from "./errors.js";
import { httpURL, saveInput } from "./input.js";
import type { CapturePreview, SourceAdapter, SaveInput } from "./types.js";

/** Shared by standalone capture and the app's external runner. Never saves or connects to MCP. */
export class AdapterRegistry {
  readonly adapters: readonly SourceAdapter[];

  constructor(adapters: readonly SourceAdapter[]) {
    const ids = new Set<string>();
    this.adapters = [...adapters];
    for (const adapter of this.adapters) {
      if (!adapter || typeof adapter.id !== "string" || !adapter.id.trim() || adapter.id.length > 100 ||
          ids.has(adapter.id) || typeof adapter.matches !== "function" || typeof adapter.extract !== "function") {
        throw new BrieflyError("invalid_input", "Adapters need a unique id of 1–100 characters, matches, and extract.");
      }
      ids.add(adapter.id);
    }
  }

  resolve(input: string | URL): { url: string; matched: boolean; adapterId: string | null } {
    const url = httpURL(input);
    const adapter = this.adapters.find((candidate) => this.matches(candidate, url));
    return { url, matched: Boolean(adapter), adapterId: adapter?.id ?? null };
  }

  async extract(id: string, input: string | URL): Promise<SaveInput> {
    const url = httpURL(input);
    const adapter = this.adapters.find((candidate) => candidate.id === id);
    if (!adapter || !this.matches(adapter, url)) {
      throw new BrieflyError("adapter_failed", "The selected adapter no longer matches this URL.");
    }
    try {
      const document = saveInput(await adapter.extract(new URL(url)));
      document.url ??= url;
      return document;
    } catch (cause) {
      throw new BrieflyError("adapter_failed", `Adapter ${id} could not extract a valid document.`, { cause });
    }
  }

  async preview(input: string | URL): Promise<CapturePreview> {
    const { url, adapterId } = this.resolve(input);
    return adapterId === null
      ? { kind: "app", url }
      : { kind: "custom", adapterId, url, document: await this.extract(adapterId, url) };
  }

  private matches(adapter: SourceAdapter, url: string): boolean {
    try {
      const matches = adapter.matches(new URL(url));
      if (typeof matches !== "boolean") throw new Error("matches must return a boolean.");
      return matches;
    } catch (cause) {
      throw new BrieflyError("adapter_failed", `Adapter ${adapter.id} could not match this resource.`, { cause });
    }
  }
}
