---
name: shared-library-deep-research
description: Plan and conduct deep research through the Shared Library desktop app. Use when the user wants an agent to identify relevant web sources, request approval for an exact URL list, import only approved URLs under a named topic, wait for automatic summaries, and synthesize or continue working from those summaries.
---

# Shared Library Deep Research

Use the app-managed CLI in `scripts/shared_library.py`. It discovers the
loopback API connection written by the running Shared Library app. Use
`python3` on macOS/Linux and `py -3` on Windows; examples below use `python3`.

## Workflow

1. Clarify the research question and identify credible, complementary sources.
   Prefer primary sources, current authoritative references, and meaningful
   viewpoint coverage. Deduplicate canonical URLs.
2. Present the proposed sources with each full URL and a one-line reason.
   **Stop and obtain explicit user approval for the exact list.**
3. Before approval, do not run `create-topic`, `add-urls`, or any other
   mutating command. If the user removes, replaces, or adds sources, submit only
   the final explicitly approved list.
4. After approval, check the app:

   ```bash
   python3 <skill-dir>/scripts/shared_library.py status
   ```

   A sandbox may block `127.0.0.1` even when Shared Library is running. If the
   workspace connection file exists but this command cannot connect, retry the
   exact CLI command with narrowly scoped localhost/network permission. Never
   print the connection file or bearer token. Ask the user to open or restart
   Shared Library only if the permitted retry also fails. Do not bypass the app
   by writing directly to `library/` or `topics.md`.
5. Create or reuse the topic:

   ```bash
   python3 <skill-dir>/scripts/shared_library.py create-topic --title "<topic>"
   ```

6. Submit the approved URLs using the returned topic ID:

   ```bash
   python3 <skill-dir>/scripts/shared_library.py add-urls \
     --topic "<topic-id>" --approved "<url-1>" "<url-2>"
   ```

   `--approved` is a deliberate safety signal. Never supply it without user
   approval in the current conversation.
7. Poll the returned job until `status` is `completed`:

   ```bash
   python3 <skill-dir>/scripts/shared_library.py job "<job-id>"
   ```

   Report per-source failures. Do not silently replace failed URLs; propose
   replacements and obtain approval again.
8. Retrieve the app-generated summaries:

   ```bash
   python3 <skill-dir>/scripts/shared_library.py items \
     --topic "<topic-id>" --variant detailed
   ```

   Start with `detailed`. Retrieve `comprehensive` for pivotal sources when
   nuance or evidence was compressed away. Use `brief` or `concise` only for
   quick orientation.
9. Continue the research from the returned summaries. Attribute claims to the
   original source URLs, compare agreements and contradictions, state gaps and
   uncertainty, and distinguish synthesis from source claims.
10. If the summaries reveal a new source gap, repeat the proposal and approval
    cycle before adding more URLs.

Read [references/api.md](references/api.md) only when troubleshooting the CLI
or using the HTTP API directly.
