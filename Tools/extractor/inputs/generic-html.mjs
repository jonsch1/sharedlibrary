import { Readability } from "@mozilla/readability";
import { parseHTML } from "linkedom";
import sanitizeHtml from "sanitize-html";

import { fetchText, isHTTPURL } from "./http.mjs";

const BINARY_CONTENT_TYPES = [
  "application/pdf",
  "application/zip",
  "application/octet-stream",
  "audio/",
  "image/",
  "video/"
];

export const genericHTMLInput = {
  id: "generic-html",
  sourceType: "web-page",
  fallbackToGeneric: false,
  matches: isHTTPURL,
  extract: extractGenericHTML
};

export async function extractGenericHTML(rawUrl, context = {}) {
  const fetched = await fetchText(rawUrl, context);
  if (
    fetched.contentType.includes("application/pdf") ||
    new TextDecoder("latin1").decode(fetched.bytes.slice(0, 5)) === "%PDF-"
  ) {
    const { extractPDF } = await import("./pdf.mjs");
    return extractPDF(rawUrl, fetched);
  }
  const { extractPublishedPodcastTranscript } = await import("./podcast.mjs");
  const podcast = await extractPublishedPodcastTranscript(rawUrl, fetched, context);
  if (podcast) return podcast;
  assertTextDocument(fetched.contentType, fetched.text);
  const extracted = extractGenericHTMLFromSource(fetched.finalURL, fetched.text);
  return {
    ...extracted,
    url: rawUrl,
    finalURL: fetched.finalURL
  };
}

export function extractGenericHTMLFromSource(rawUrl, html) {
  const metadata = extractHTMLMetadata(html, rawUrl);
  const readability = extractReadability(html, rawUrl);
  const structuredText = extractStructuredText(html, rawUrl);
  const content =
    usefulText(readability?.textContent, 180) ??
    usefulText(metadata.articleBody, 120) ??
    usefulText(structuredText, 1) ??
    usefulText(metadata.description, 1);

  if (!content) {
    throw new Error("The page did not contain extractable text.");
  }

  return {
    url: rawUrl,
    canonicalURL: metadata.canonicalURL,
    faviconURL: metadata.faviconURL,
    title: metadata.title ?? readability?.title ?? null,
    description: metadata.description ?? readability?.excerpt ?? null,
    siteName: metadata.siteName ?? hostname(rawUrl),
    content
  };
}

export function extractHTMLMetadata(html, rawUrl) {
  const document = parseDocument(html, rawUrl);
  const jsonLD = extractJSONLD(document);
  const canonicalURL = validWebURL(
    document.querySelector('link[rel="canonical"]')?.getAttribute("href"),
    rawUrl
  );
  const faviconURL = validWebURL(
    [...document.querySelectorAll("link[rel]")]
      .find((element) =>
        element.getAttribute("rel")?.toLowerCase().split(/\s+/u).some((value) =>
          value === "icon" || value.endsWith("-icon")
        )
      )
      ?.getAttribute("href"),
    rawUrl
  );

  return {
    articleBody: firstText(jsonLD.map((entry) => entry.articleBody)),
    canonicalURL,
    faviconURL,
    description: firstText([
      metaContent(document, "property", "og:description"),
      metaContent(document, "name", "description"),
      metaContent(document, "name", "twitter:description"),
      ...jsonLD.map((entry) => entry.description)
    ]),
    siteName: firstText([
      metaContent(document, "property", "og:site_name"),
      metaContent(document, "name", "application-name"),
      ...jsonLD.map((entry) => entry.publisher?.name)
    ]),
    title: firstText([
      metaContent(document, "property", "og:title"),
      metaContent(document, "name", "twitter:title"),
      ...jsonLD.map((entry) => entry.headline),
      ...jsonLD.map((entry) => entry.name),
      document.querySelector("title")?.textContent
    ])
  };
}

function assertTextDocument(contentType, text) {
  if (BINARY_CONTENT_TYPES.some((candidate) => contentType.includes(candidate))) {
    throw new Error(`Unsupported link content type: ${contentType.split(";")[0]}`);
  }
  if (looksBinary(text)) {
    throw new Error("Unsupported binary link content.");
  }
}

function extractReadability(html, rawUrl) {
  try {
    const withoutStyles = html.replace(/<style\b[^>]*>[\s\S]*?<\/style>/giu, "");
    return new Readability(parseDocument(withoutStyles, rawUrl)).parse();
  } catch {
    return null;
  }
}

function extractStructuredText(html, rawUrl) {
  const safeHTML = sanitizeHtml(html, {
    allowedTags: [
      "article", "main", "section", "div", "p", "h1", "h2", "h3", "h4",
      "h5", "h6", "ol", "ul", "li", "blockquote", "pre", "code", "br"
    ],
    allowedAttributes: {},
    nonTextTags: [
      "script", "style", "noscript", "template", "svg", "canvas", "iframe",
      "object", "embed", "nav", "footer", "form", "aside"
    ]
  });
  const document = parseDocument(safeHTML, rawUrl);
  const segments = [];
  for (const element of document.querySelectorAll(
    "h1,h2,h3,h4,h5,h6,p,li,blockquote,pre"
  )) {
    const text = normalizedText(element.textContent);
    if (!text) continue;
    const tag = element.tagName.toLowerCase();
    if (tag === "li") {
      segments.push(`• ${text}`);
    } else {
      segments.push(text);
    }
  }
  if (segments.length > 0) {
    return [...new Set(segments)].join("\n");
  }
  return normalizedText(document.body?.textContent);
}

function parseDocument(html, rawUrl) {
  const source = /<html(?:\s|>)/iu.test(html)
    ? html
    : `<!doctype html><html><body>${html}</body></html>`;
  const pageURL = new URL(rawUrl);
  const document = parseHTML(source, { location: pageURL }).document;
  Object.defineProperties(document, {
    documentURI: { configurable: true, value: pageURL.href },
    URL: { configurable: true, value: pageURL.href }
  });
  const createElement = document.createElement.bind(document);
  document.createElement = (tagName, options) =>
    createElement(tagName.toLowerCase(), options);
  return document;
}

function extractJSONLD(document) {
  const entries = [];
  for (const script of document.querySelectorAll('script[type="application/ld+json"]')) {
    try {
      flattenJSONLD(JSON.parse(script.textContent ?? ""), entries);
    } catch {
      // Invalid structured data should not make an otherwise readable page fail.
    }
  }
  return entries;
}

function flattenJSONLD(value, entries) {
  if (Array.isArray(value)) {
    for (const item of value) flattenJSONLD(item, entries);
    return;
  }
  if (!value || typeof value !== "object") return;
  entries.push(value);
  if (Array.isArray(value["@graph"])) {
    for (const item of value["@graph"]) flattenJSONLD(item, entries);
  }
}

function metaContent(document, attribute, value) {
  return document
    .querySelector(`meta[${attribute}="${value}"]`)
    ?.getAttribute("content");
}

function firstText(values) {
  for (const value of values) {
    const text = normalizedText(value);
    if (text) return text;
  }
  return null;
}

function usefulText(value, minimumLength) {
  const text = normalizedText(value);
  return text && text.length >= minimumLength ? text : null;
}

function normalizedText(value) {
  return typeof value === "string"
    ? value.replace(/\u00a0/gu, " ").replace(/[ \t]+/gu, " ").replace(/\n{3,}/gu, "\n\n").trim()
    : "";
}

function validWebURL(value, baseURL) {
  if (typeof value !== "string" || !value.trim()) return null;
  try {
    const url = new URL(value, baseURL);
    return url.protocol === "http:" || url.protocol === "https:"
      ? url.toString()
      : null;
  } catch {
    return null;
  }
}

function hostname(rawUrl) {
  return new URL(rawUrl).hostname.replace(/^www\./iu, "");
}

function looksBinary(text) {
  const sample = text.slice(0, 4096);
  if (!sample) return false;
  let suspicious = 0;
  for (const character of sample) {
    const code = character.codePointAt(0) ?? 0;
    if (code === 0) return true;
    if (code < 8 || (code > 13 && code < 32)) suspicious += 1;
  }
  return suspicious / sample.length > 0.1;
}
