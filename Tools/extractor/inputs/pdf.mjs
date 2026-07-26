import { getDocument } from "pdfjs-dist/legacy/build/pdf.mjs";

export async function extractPDF(rawUrl, fetched) {
  const task = getDocument({
    data: fetched.bytes,
    isEvalSupported: false,
    useSystemFonts: true
  });

  try {
    const document = await task.promise;
    const pages = [];
    for (let pageNumber = 1; pageNumber <= document.numPages; pageNumber += 1) {
      const page = await document.getPage(pageNumber);
      const text = await page.getTextContent();
      const content = text.items
        .map((item) =>
          typeof item.str === "string"
            ? `${item.str}${item.hasEOL ? "\n" : " "}`
            : ""
        )
        .join("")
        .replace(/[ \t]+\n/gu, "\n")
        .replace(/[ \t]{2,}/gu, " ")
        .trim();
      if (content) pages.push(content);
      page.cleanup();
    }
    if (!pages.length) {
      throw new Error(
        "This PDF does not contain extractable text. Scanned PDFs are not supported yet."
      );
    }

    const metadata = await document.getMetadata().catch(() => null);
    const title =
      cleanText(metadata?.info?.Title) ||
      cleanText(metadata?.metadata?.get?.("dc:title")) ||
      filenameTitle(fetched.finalURL);
    return {
      url: rawUrl,
      title,
      content: pages.join("\n\n"),
      extractor: "pdf",
      sourceType: "document"
    };
  } catch (error) {
    if (error?.name === "PasswordException") {
      throw new Error("Password-protected PDFs are not supported.");
    }
    throw error;
  } finally {
    await task.destroy();
  }
}

function filenameTitle(rawUrl) {
  try {
    const filename = decodeURIComponent(new URL(rawUrl).pathname.split("/").at(-1) ?? "");
    return cleanText(filename.replace(/\.pdf$/iu, "").replace(/[-_]+/gu, " "));
  } catch {
    return "";
  }
}

function cleanText(value) {
  return typeof value === "string" ? value.replace(/\s+/gu, " ").trim() : "";
}
