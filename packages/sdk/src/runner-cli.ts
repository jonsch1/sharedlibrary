#!/usr/bin/env node
import { execFile } from "node:child_process";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";
import { Briefly } from "./index.js";
import { AdapterRegistry } from "./adapters.js";
import { startAdapterRunner } from "./runner.js";
import type { SourceAdapter } from "./types.js";

const execFileAsync = promisify(execFile);
const label = "fyi.readbriefly.adapters";
const agentPath = join(homedir(), "Library", "LaunchAgents", `${label}.plist`);
const args = process.argv.slice(2);
const [command, file] = args;

async function adapters(path: string): Promise<SourceAdapter[]> {
  const module: unknown = await import(pathToFileURL(resolve(path)).href);
  const value = (module as { default?: unknown }).default;
  if (!Array.isArray(value) || !value.length) throw new Error("Export a nonempty default array of source adapters.");
  return [...new AdapterRegistry(value).adapters];
}

function xml(value: string): string {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;").replaceAll("'", "&apos;");
}

async function main(): Promise<void> {
  if ((command === "run" || command === "install") && file && args.length === 2) {
    const sourceAdapters = await adapters(file);
    if (command === "run") {
      const runner = await startAdapterRunner({
        adapters: sourceAdapters,
        onStatus: (state) => console.log(state.connected
          ? `Connected to Briefly with ${state.adapterCount} custom handlers.`
          : `Waiting for Briefly (${state.error ?? "disconnected"}).`),
      });
      if (!runner.state.connected) console.log("Open Briefly; this runner will connect automatically.");
      const stop = () => { void runner.close().catch(() => { process.exitCode = 1; }); };
      process.once("SIGINT", stop);
      process.once("SIGTERM", stop);
      return;
    }
    if (process.platform !== "darwin") throw new Error("Login installation requires macOS.");
    const logDirectory = join(homedir(), "Library", "Logs", "Briefly");
    await mkdir(dirname(agentPath), { recursive: true });
    await mkdir(logDirectory, { recursive: true, mode: 0o700 });
    const programArgs = [process.execPath, fileURLToPath(import.meta.url), "run", resolve(file)];
    const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${label}</string>
<key>ProgramArguments</key><array>${programArgs.map((arg) => `<string>${xml(arg)}</string>`).join("")}</array>
<key>WorkingDirectory</key><string>${xml(dirname(resolve(file)))}</string>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>15</integer>
<key>StandardOutPath</key><string>${xml(join(logDirectory, "adapter-runner.log"))}</string>
<key>StandardErrorPath</key><string>${xml(join(logDirectory, "adapter-runner-error.log"))}</string>
</dict></plist>\n`;
    const domain = `gui/${process.getuid!()}`;
    const temporaryPath = `${agentPath}.${randomUUID()}.tmp`;
    try {
      await writeFile(temporaryPath, plist, { mode: 0o600, flag: "wx" });
      await execFileAsync("/bin/launchctl", ["bootout", `${domain}/${label}`]).catch(() => {});
      await rename(temporaryPath, agentPath);
    } finally { await rm(temporaryPath, { force: true }); }
    await execFileAsync("/bin/launchctl", ["bootstrap", domain, agentPath]);
    console.log("Installed the adapter runner for this login and future logins. Open Briefly and check Settings → Capture.");
    return;
  }
  if (command === "uninstall" && args.length === 1) {
    if (process.platform !== "darwin") throw new Error("Login installation requires macOS.");
    await readFile(agentPath); // Report a missing installation rather than claiming it was removed.
    await execFileAsync("/bin/launchctl", ["bootout", `gui/${process.getuid!()}/${label}`]).catch(() => {});
    await rm(agentPath);
    console.log("Removed the login adapter runner. Your adapter files were kept.");
    return;
  }
  if (command === "status" && args.length === 1) {
    const briefly = new Briefly();
    try { console.log(JSON.stringify(await briefly.adapterRunner({ action: "status" }))); }
    finally { await briefly.close(); }
    return;
  }
  throw new Error("Usage: briefly-adapters run <adapters.mjs> | install <adapters.mjs> | uninstall | status");
}

try { await main(); }
catch (error) {
  console.error(error instanceof Error ? error.message : "Adapter runner failed.");
  process.exitCode = 1;
}
