# Briefly Agent Instructions

- After changing `Electron/`, run its tests, typecheck, and build. Package and
  restart the Electron app after desktop-facing changes so the user can test it.
- After changing `Web/`, run its checks, worker tests, and Sites build. Deploy
  completed web changes through the existing Sites project.

## Generated Briefly workspace instructions

The `AGENTS.md` populated in a user's Briefly workspace must make the
following document behavior explicit:

- When the user asks to create, write, compile, consolidate, or put material
  into a “document,” default to a Markdown root capture at
  `library/<descriptive-name>.md`.
- Treat “document” as Markdown unless the user explicitly requests another
  format such as DOCX or PDF.
- Do not place the default document at the workspace root or create a separate
  documents directory.
- When another format is explicitly requested, also create and retain the
  Markdown source in `library/` unless the user explicitly opts out.
- Prefer a clear title, useful headings, source links, and readable Markdown
  over document-specific styling.
