import { Briefly, BrieflyError, type SourceAdapter } from "@readbriefly/sdk";

// Copy this adapter into your own project and change its extraction behavior there.
// GitHub's issue body is already Markdown, so this example needs no HTML parser.
const issuePath = /^\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)\/issues\/(\d+)\/?$/;
export const githubIssue: SourceAdapter = {
  id: "personal.github-issue",
  matches: (url) => url.origin === "https://github.com" && issuePath.test(url.pathname),
  async extract(url) {
    const match = issuePath.exec(url.pathname);
    if (!match) throw new Error("Expected a GitHub issue URL.");
    const [, owner, repository, number] = match;
    const response = await fetch(`https://api.github.com/repos/${owner}/${repository}/issues/${number}`, {
      headers: { Accept: "application/vnd.github+json", "User-Agent": "readbriefly-sdk-example" },
      signal: AbortSignal.timeout(20_000),
    });
    if (!response.ok) throw new Error(`GitHub returned HTTP ${response.status}.`);
    const issue: unknown = await response.json();
    if (!issue || typeof issue !== "object" || !("title" in issue) || typeof issue.title !== "string" ||
        !("body" in issue) || (issue.body !== null && typeof issue.body !== "string")) {
      throw new Error("GitHub did not return an issue title and body.");
    }
    return {
      title: issue.title,
      content: `# ${issue.title}\n\n${issue.body || "This issue has no description."}`,
      url: `https://github.com/${owner}/${repository}/issues/${number}`,
    };
  },
};

const [input, flag] = process.argv.slice(2);
if (!input || (flag !== undefined && flag !== "--save") || process.argv.length > 4) {
  console.error("Usage: node examples/github-issue.ts <url> [--save]");
  process.exitCode = 1;
} else {
  const briefly = new Briefly({ adapters: [githubIssue] });
  try {
    // Default preview runs extraction but never connects to or saves in Briefly.
    const result = flag === "--save" ? await briefly.capture(input) : await briefly.preview(input);
    console.log(JSON.stringify(result, null, 2));
  } catch (error) {
    console.error(error instanceof BrieflyError ? `${error.code}: ${error.message}` : "Capture failed.");
    process.exitCode = 1;
  } finally {
    await briefly.close();
  }
}
