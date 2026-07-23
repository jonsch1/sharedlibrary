import { cpSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const buildDirectory = resolve(root, 'build');
const distributionDirectory = resolve(root, 'dist');
const clientDirectory = resolve(distributionDirectory, 'client');
const serverDirectory = resolve(distributionDirectory, 'server');

rmSync(distributionDirectory, { recursive: true, force: true });
mkdirSync(serverDirectory, { recursive: true });
cpSync(buildDirectory, clientDirectory, { recursive: true });

writeFileSync(
	resolve(serverDirectory, 'index.js'),
	`const worker = {
  async fetch(request, env) {
    const response = await env.ASSETS.fetch(request);
    if (response.status !== 404 || request.method !== "GET") return response;
    const acceptsHTML = request.headers.get("accept")?.includes("text/html") ?? false;
    if (!acceptsHTML) return response;
    return env.ASSETS.fetch(new Request(new URL("/", request.url), request));
  }
};

export default worker;
`
);
