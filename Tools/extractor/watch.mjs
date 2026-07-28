#!/usr/bin/env node
import { discoverSource } from "./inputs/feed.mjs";

const source = process.argv.slice(2).join(" ").trim();
if (!source) {
  console.error("Usage: node watch.mjs <source URL or arxiv:query>");
  process.exit(2);
}

try {
  process.stdout.write(`${JSON.stringify(await discoverSource(source))}\n`);
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
