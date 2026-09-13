# Briefly MCP

The `briefly-mcp` executable exposes Briefly's local library to agent clients.
It depends on `BrieflyCore` from the sibling Apple package and the Swift MCP SDK.
The Apple Xcode project also builds and signs this executable for embedding in
the macOS app, inside `Contents/Helpers/BrieflyMCP.app`. This gives the helper
its own sandbox container and preserves the existing shared app-group IPC connection.

From the repository root:

```bash
npm run build:mcp
npm run test:sdk
./packages/apple/scripts/package-agent-plugin.sh /tmp/briefly-plugin
```

The standalone helper is built at `.build/debug/briefly-mcp` inside this package.
`plugin/` contains the distributable agent plugin and its installed-app launcher.
See [the MCP API documentation](../../docs/AGENT_MCP_API.md) for tools, library
access, and plugin installation.
