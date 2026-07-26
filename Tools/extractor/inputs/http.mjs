const DEFAULT_TIMEOUT_MILLISECONDS = 120_000;
const DEFAULT_MAXIMUM_BYTES = 20_000_000;

const DEFAULT_HEADERS = {
  "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,*/*;q=0.1",
  "Accept-Language": "en-US,en;q=0.9",
  "Cache-Control": "no-cache",
  "User-Agent":
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0 Safari/537.36"
};

export async function fetchText(rawUrl, {
  body,
  fetchImpl = fetch,
  headers = {},
  maximumBytes = DEFAULT_MAXIMUM_BYTES,
  method = "GET",
  onProgress,
  timeoutMilliseconds = DEFAULT_TIMEOUT_MILLISECONDS
} = {}) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMilliseconds);
  onProgress?.({ kind: "fetch-start", url: rawUrl });

  try {
    const response = await fetchImpl(rawUrl, {
      body,
      headers: { ...DEFAULT_HEADERS, ...headers },
      method,
      redirect: "follow",
      signal: controller.signal
    });
    if (!response.ok) {
      throw new Error(`Request failed: ${response.status} ${response.statusText}`);
    }

    const declaredLength = Number(response.headers?.get?.("content-length"));
    if (Number.isFinite(declaredLength) && declaredLength > maximumBytes) {
      throw new Error("The response was too large to import.");
    }

    const contentType =
      response.headers?.get?.("content-type")?.toLowerCase() ?? "";
    let bytes;
    let text;
    if (typeof response.arrayBuffer === "function") {
      bytes = new Uint8Array(await response.arrayBuffer());
      text = isBinaryContentType(contentType)
        ? ""
        : new TextDecoder().decode(bytes);
    } else {
      text = await response.text();
      bytes = new TextEncoder().encode(text);
    }
    const downloadedBytes = bytes.byteLength;
    if (downloadedBytes > maximumBytes) {
      throw new Error("The response was too large to import.");
    }

    const finalURL =
      typeof response.url === "string" && response.url.trim()
        ? response.url
        : rawUrl;
    onProgress?.({
      kind: "fetch-done",
      url: finalURL,
      downloadedBytes
    });
    return {
      bytes,
      contentType,
      finalURL,
      headers: response.headers?.entries
        ? Object.fromEntries(response.headers.entries())
        : {},
      requestedURL: rawUrl,
      status: response.status,
      statusText: response.statusText,
      text
    };
  } catch (error) {
    if (controller.signal.aborted) {
      throw new Error(`Request timed out after ${Math.round(timeoutMilliseconds / 1000)} seconds.`);
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

export function isHTTPURL(rawUrl) {
  try {
    const url = new URL(rawUrl);
    return url.protocol === "http:" || url.protocol === "https:";
  } catch {
    return false;
  }
}

function isBinaryContentType(contentType) {
  return [
    "application/octet-stream",
    "application/pdf",
    "application/zip",
    "audio/",
    "image/",
    "video/"
  ].some((candidate) => contentType.includes(candidate));
}
