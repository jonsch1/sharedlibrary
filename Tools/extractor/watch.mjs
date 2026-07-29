#!/usr/bin/env node
import { discoverSource } from "./inputs/feed.mjs";

const args = process.argv.slice(2);
const limitOption = args.indexOf("--limit");
const maximumItems =
  limitOption >= 0 ? Number(args.splice(limitOption, 2)[1]) : undefined;
const source = args.join(" ").trim();
if (!source) {
  console.error("Usage: node watch.mjs <source URL or arxiv:query> [--limit N]");
  process.exit(2);
}

try {
  process.stdout.write(
    `${JSON.stringify(await discoverSource(source, { maximumItems }))}\n`
  );
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
