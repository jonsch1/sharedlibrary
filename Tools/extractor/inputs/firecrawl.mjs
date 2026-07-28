export async function scrapeWithFirecrawl(rawUrl, {
  endpoint,
  token,
  fetchImpl = fetch
} = {}) {
  if (!endpoint?.trim() || !token?.trim()) {
    throw new Error("Briefly web extraction is unavailable.");
  }

  const response = await fetchImpl(endpoint, {
    method: "POST",
    headers: {
      "Cookie": `shared_library_session=${token.trim()}`,
      "Origin": new URL(endpoint).origin,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({ url: rawUrl })
  });
  const payload = await response.json().catch(() => null);
  if (!response.ok || !payload?.success) {
    throw new Error(
      cleanText(payload?.error) ||
        `Firecrawl request failed: ${response.status} ${response.statusText}`
    );
  }

  const metadata = payload.data?.metadata ?? {};
  const statusCode = Number(metadata.statusCode);
  if (Number.isFinite(statusCode) && statusCode >= 400) {
    throw new Error(`Firecrawl reached a ${statusCode} error page.`);
  }
  if (cleanText(metadata.error)) throw new Error(cleanText(metadata.error));

  const content = cleanText(payload.data?.markdown);
  const title = cleanText(metadata.title);
  if (!content) throw new Error("Firecrawl did not return readable content.");
  if (
    /(?:page not found|gateway time-?out)/iu.test(content.slice(0, 2_000)) ||
    /(?:checking your browser|recaptcha|page not found|gateway time-?out)/iu.test(
      title
    ) ||
    (content.split(/\s+/u).length < 500 &&
      /(?:checking your browser|recaptcha|please wait for verification)/iu.test(
        content.slice(0, 800)
      ))
  ) {
    throw new Error("Firecrawl returned an access or error interstitial.");
  }
  return {
    url: cleanText(metadata.sourceURL) || cleanText(metadata.url) || rawUrl,
    title: title || null,
    description: cleanText(metadata.description) || null,
    siteName: cleanText(metadata.ogSiteName) || null,
    content
  };
}

function cleanText(value) {
  return typeof value === "string" ? value.trim() : "";
}
