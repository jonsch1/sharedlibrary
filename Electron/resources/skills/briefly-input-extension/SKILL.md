---
name: briefly-input-extension
description: Create, repair, and test workspace-local Briefly link input extensions. Use when Briefly cannot extract a website correctly, a user asks an agent to add support for a site or URL pattern, or an existing `.briefly/inputs/` package needs debugging.
---

# Briefly Input Extension

Build narrowly matched input packages under `<workspace>/.briefly/inputs/`.
Briefly discovers valid packages on every capture, so do not restart the app.

## Workflow

1. Inspect the target URL and identify the smallest reliable extraction source:
   embedded JSON, JSON-LD, a public JSON endpoint, or site HTML.
2. Search `.briefly/inputs/` for an existing package matching the host. Inspect
   and update it when present; do not scaffold over it.
3. For a new package, run:

   ```bash
   python3 <skill-dir>/scripts/create_input.py \
     --id "<lowercase-id>" \
     --host "<exact-host>" \
     --source-type "<source-type>"
   ```

   Add `--path-prefix "/articles/"` when only part of the host needs custom
   handling. On Windows, use `py -3`.
4. Read [references/api.md](references/api.md), then implement `input.mjs`.
   Keep `input.json` matching as narrow as possible. Prefer the supplied
   `briefly.fetch`, `briefly.fetchText`, and `briefly.extractHTML` APIs.
5. Never read application configuration, workspace documents, credentials, or
   unrelated local files. Extensions receive no Briefly secrets and run without
   filesystem-write or child-process permission.
6. Add representative, offline fixtures for successful extraction and malformed
   or incomplete site responses. Run:

   ```bash
   node --test <workspace>/.briefly/inputs/<id>/*.test.mjs
   ```

7. Capture the target URL in Briefly. If the extension fails, use the
   `Workspace input "<id>" failed during ...` diagnostic to fix the relevant
   phase. With `"fallback": "builtin"`, Briefly continues through its built-in
   pipeline while the extension is being repaired.

Return clean source content, not summaries. Briefly performs summarization after
the input succeeds.
