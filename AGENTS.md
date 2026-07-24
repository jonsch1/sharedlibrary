# Shared Library Agent Instructions

- After changing `Electron/`, run its tests, typecheck, and build. Package and
  restart the Electron app after desktop-facing changes so the user can test it.
- After changing `Web/`, run its checks, worker tests, and Sites build. Deploy
  completed web changes through the existing Sites project.
