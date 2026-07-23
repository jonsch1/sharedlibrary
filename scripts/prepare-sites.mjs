import { copyFileSync, cpSync, mkdirSync, rmSync } from 'node:fs';
import { resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const buildDirectory = resolve(root, 'build');
const distributionDirectory = resolve(root, 'dist');
const clientDirectory = resolve(distributionDirectory, 'client');
const serverDirectory = resolve(distributionDirectory, 'server');

rmSync(distributionDirectory, { recursive: true, force: true });
mkdirSync(serverDirectory, { recursive: true });
cpSync(buildDirectory, clientDirectory, { recursive: true });
copyFileSync(resolve(root, 'worker/index.js'), resolve(serverDirectory, 'index.js'));
