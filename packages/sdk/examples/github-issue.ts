import { Briefly, BrieflyError } from "@readbriefly/sdk";

import { githubIssue } from "./adapters.ts";

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
