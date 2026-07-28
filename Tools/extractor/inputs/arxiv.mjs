import { fetchText } from "./http.mjs";

const ARXIV_HOSTS = new Set(["arxiv.org", "www.arxiv.org"]);

export const arxivInput = {
  id: "arxiv",
  sourceType: "paper",
  fallbackToGeneric: false,
  matches(rawUrl) {
    try {
      return ARXIV_HOSTS.has(new URL(rawUrl).hostname.toLowerCase());
    } catch {
      return false;
    }
  },
  extract: extractArxiv
};

export async function extractArxiv(rawUrl, context = {}) {
  const markxivURL = new URL(rawUrl);
  markxivURL.hostname = "markxiv.org";
  const fetched = await fetchText(markxivURL.toString(), context);
  const content = fetched.text.trim();

  if (!content) throw new Error("Markxiv did not return readable content.");

  return {
    url: rawUrl,
    title: content.match(/^#\s+(.+)$/mu)?.[1].trim() ?? null,
    siteName: "arXiv",
    content,
    finalURL: fetched.finalURL
  };
}
