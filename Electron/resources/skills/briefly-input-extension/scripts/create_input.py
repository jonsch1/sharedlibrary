#!/usr/bin/env python3
"""Scaffold a workspace-local Briefly input extension."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


IDENTIFIER = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
HOST = re.compile(r"^(?:\*\.)?[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--id", required=True, dest="input_id")
    parser.add_argument("--host", required=True)
    parser.add_argument("--source-type", default="article")
    parser.add_argument("--path-prefix", action="append", default=[])
    parser.add_argument("--workspace", type=Path)
    return parser.parse_args()


def workspace_for_script() -> Path:
    return Path(__file__).resolve().parents[4]


def validate(args: argparse.Namespace) -> None:
    if not IDENTIFIER.fullmatch(args.input_id):
        raise SystemExit("--id must use lowercase letters, numbers, and single hyphens.")
    if not IDENTIFIER.fullmatch(args.source_type):
        raise SystemExit(
            "--source-type must use lowercase letters, numbers, and single hyphens."
        )
    host = args.host.strip().lower().rstrip(".")
    if "." not in host.removeprefix("*.") or not HOST.fullmatch(host):
        raise SystemExit("--host must be an exact hostname or a *. subdomain wildcard.")
    args.host = host
    for prefix in args.path_prefix:
        if not prefix.startswith("/") or "?" in prefix or "#" in prefix:
            raise SystemExit("--path-prefix values must begin with / and omit ? and #.")


def main() -> None:
    args = parse_args()
    validate(args)
    workspace = (args.workspace or workspace_for_script()).resolve()
    package = workspace / ".briefly" / "inputs" / args.input_id
    package.mkdir(parents=True, exist_ok=False)
    (package / "fixtures").mkdir()

    manifest = {
        "apiVersion": 1,
        "id": args.input_id,
        "sourceType": args.source_type,
        "priority": 100,
        "match": {
            "hosts": [args.host],
            "pathPrefixes": args.path_prefix,
        },
        "entry": "input.mjs",
        "fallback": "builtin",
    }
    write(package / "input.json", json.dumps(manifest, indent=2) + "\n")
    write(
        package / "input.mjs",
        """export default {
  async extract(request, briefly) {
    const response = await briefly.fetch(request.url);
    const html = await response.text();
    const extracted = briefly.extractHTML({
      url: response.url || request.url.href,
      html
    });

    return {
      sourceURL: request.url.href,
      title: extracted.title,
      description: extracted.description,
      siteName: extracted.siteName,
      content: extracted.content
    };
  }
};
""",
    )
    write(
        package / "fixtures" / "page.html",
        """<!doctype html>
<html>
  <head><title>Fixture title</title></head>
  <body><article><p>Replace this fixture with representative source content.</p></article></body>
</html>
""",
    )
    write(
        package / "input.test.mjs",
        """import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import input from "./input.mjs";

test("extracts the site fixture", async () => {
  const html = await readFile(new URL("./fixtures/page.html", import.meta.url), "utf8");
  const result = await input.extract(
    { url: new URL("https://HOST/"), options: {}, signal: new AbortController().signal },
    {
      fetch: async () => ({ url: "https://HOST/", text: async () => html }),
      extractHTML: ({ url }) => ({
        url,
        title: "Fixture title",
        description: null,
        siteName: "HOST",
        content: "Replace this fixture with representative source content."
      })
    }
  );

  assert.equal(result.title, "Fixture title");
  assert.match(result.content, /representative source content/);
});
""".replace("HOST", args.host.removeprefix("*.")),
    )
    print(package)


def write(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")


if __name__ == "__main__":
    main()
