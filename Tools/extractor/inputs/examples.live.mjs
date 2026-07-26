import assert from "node:assert/strict";
import test from "node:test";

import { extractLink } from "./registry.mjs";

const examples = [
  {
    name: "X post",
    url: "https://x.com/jack/status/20",
    extractor: "x",
    sourceType: "social-post",
    titleIncludes: "just setting up my twttr",
    contentIncludes: ["jack (@jack)", "just setting up my twttr"],
    minimumWords: 10
  },
  {
    name: "X Article",
    url: "https://x.com/cerebras/status/2077822555159945507",
    extractor: "x",
    sourceType: "social-post",
    titleIncludes: "How we built our knowledge base",
    contentIncludes: [
      "Employees ask our internal knowledge base more than 15,000 questions every day.",
      "Meeting data where it lives"
    ],
    minimumWords: 2_000
  },
  {
    name: "Bluesky post",
    url: "https://bsky.app/profile/bsky.app/post/3kh5rbndrjd2x",
    extractor: "bluesky",
    sourceType: "social-post",
    titleIncludes: "1.60 is rolling out now",
    contentIncludes: [
      "Bluesky (@bsky.app)",
      "Posts, profiles, and user search are now available without login!"
    ],
    minimumWords: 50
  },
  {
    name: "Threads post",
    url: "https://www.threads.com/@threads/post/CwVVlQlOe53",
    extractor: "threads",
    sourceType: "social-post",
    titleIncludes: "Threads (@threads) on Threads",
    contentIncludes: [
      "Threads on web is here",
      "Everything you need to know"
    ],
    minimumWords: 8
  },
  {
    name: "YouTube video",
    url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    extractor: "youtube",
    sourceType: "video",
    titleIncludes: "Never Gonna Give You Up",
    contentIncludes: [
      "Never gonna give you up"
    ],
    minimumWords: 200
  },
  {
    name: "ordinary blog article",
    url: "https://github.blog/news-insights/company-news/an-update-on-github-availability/",
    extractor: "generic-html",
    sourceType: "web-page",
    titleIncludes: "An update on GitHub availability",
    contentIncludes: [
      "I wanted to give an update on GitHub’s availability",
      "Our priorities are clear: availability first"
    ],
    minimumWords: 1_000
  }
];

test("real public input examples produce recognizable output", async (t) => {
  for (const example of examples) {
    await t.test(`${example.name}: ${example.url}`, async (t) => {
      const result = await extractLink(example.url);

      assert.equal(result.url, example.url);
      assert.equal(result.extractor, example.extractor);
      assert.equal(result.sourceType, example.sourceType);
      assert.match(result.title ?? "", new RegExp(escapeRegex(example.titleIncludes), "u"));
      for (const expectedText of example.contentIncludes) {
        assert.ok(
          result.content.includes(expectedText),
          `Output did not include ${JSON.stringify(expectedText)}`
        );
      }
      assert.ok(result.wordCount >= example.minimumWords);
      assert.equal(result.totalCharacters, result.content.length);
      t.diagnostic(`${result.title} — ${result.wordCount} words`);
    });
  }
});

function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}
