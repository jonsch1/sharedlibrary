/** Source content and optional summaries. The URL is identity/provenance, never fetched by save. */
export interface SaveInput {
  title: string;
  content: string;
  url?: string;
  concise?: string;
  detailed?: string;
}

/** Processing means saved without a summary; it does not guarantee an active processing job. */
export interface WriteResult {
  id: string;
  status: "ready" | "processing";
}

export interface SearchInput {
  q?: string;
  limit?: number;
}

export interface SearchResult {
  items: Array<{ id: string; title: string; snippet?: string }>;
}

export interface ReadInput {
  id: string;
  detail?: boolean;
  cursor?: number;
}

export type ReadResult =
  | { id: string; title: string; text: string; next?: number }
  | { id: string; title: string; status: "processing" };

/** First matching adapter wins. Extraction failures never fall back to native ingestion. */
export interface SourceAdapter {
  id: string;
  matches(url: URL): boolean;
  extract(url: URL): SaveInput | Promise<SaveInput>;
}

export interface BrieflyOptions {
  adapters?: readonly SourceAdapter[];
  /** Absolute path to the installed app's briefly-mcp executable, or a development helper. */
  helperPath?: string;
  /** MCP request deadline, including native extraction. Defaults to five minutes. */
  requestTimeoutMs?: number;
}

export type CapturePreview =
  | { kind: "custom"; adapterId: string; url: string; document: SaveInput }
  | { kind: "native"; url: string };
