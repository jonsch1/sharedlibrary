import { copyFileSync, cpSync, mkdirSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const buildDirectory = resolve(root, 'build');
const distributionDirectory = resolve(root, 'dist');
const clientDirectory = resolve(distributionDirectory, 'client');
const serverDirectory = resolve(distributionDirectory, 'server');
const hostingDirectory = resolve(distributionDirectory, '.openai');

const listFiles = (directory) =>
	readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
		const path = resolve(directory, entry.name);
		return entry.isDirectory() ? listFiles(path) : [path];
	});

const runtimeIdPattern = /__sveltekit_([a-z0-9]+)/g;
const collectRuntimeIds = (files) => {
	const ids = new Set();
	for (const file of files) {
		const contents = readFileSync(file, 'utf8');
		for (const match of contents.matchAll(runtimeIdPattern)) ids.add(match[1]);
	}
	return ids;
};

const htmlRuntimeIds = collectRuntimeIds(
	listFiles(buildDirectory).filter((file) => file.endsWith('.html'))
);
const javascriptRuntimeIds = collectRuntimeIds(
	listFiles(resolve(buildDirectory, '_app')).filter((file) => file.endsWith('.js'))
);

if (
	htmlRuntimeIds.size !== 1 ||
	javascriptRuntimeIds.size !== 1 ||
	[...htmlRuntimeIds][0] !== [...javascriptRuntimeIds][0]
) {
	throw new Error(
		`SvelteKit hydration runtime mismatch: HTML=${[...htmlRuntimeIds].join(',') || 'missing'} JS=${[...javascriptRuntimeIds].join(',') || 'missing'}`
	);
}

rmSync(distributionDirectory, { recursive: true, force: true });
mkdirSync(serverDirectory, { recursive: true });
mkdirSync(hostingDirectory, { recursive: true });
cpSync(buildDirectory, clientDirectory, { recursive: true });
copyFileSync(resolve(root, 'worker/index.js'), resolve(serverDirectory, 'index.js'));
copyFileSync(resolve(root, '.openai/hosting.json'), resolve(hostingDirectory, 'hosting.json'));
