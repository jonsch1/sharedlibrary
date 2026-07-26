import { createHash, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import {
  chmod,
  cp,
  mkdir,
  readFile,
  rename,
  rm,
  unlink,
  writeFile
} from 'node:fs/promises';
import { createServer } from 'node:http';
import type {
  IncomingMessage,
  Server,
  ServerResponse
} from 'node:http';
import type { AddressInfo } from 'node:net';
import { dirname, join } from 'node:path';

import {
  libraryVariants,
  type LibraryVariant,
  type TopicDefinition
} from '../shared/contracts.js';
import type { ExtractedContent } from './extraction.js';
import { LibraryService } from './library.js';

const apiVersion = 1;
const maximumBodyBytes = 256 * 1024;
const maximumURLsPerJob = 24;
// Library processing renames a source and all summary companions atomically as a
// group. Keep imports serialized so two identical generated filenames cannot race.
const jobConcurrency = 1;
const connectionRelativePath = join('.shared-library', 'agent-api.json');
const legacyInstalledSkillRelativePath = join(
  '.agents',
  'skills',
  'shared-library-deep-research'
);

export interface BundledAgentSkill {
  name: string;
  sourcePath: string;
}

type AgentSourceStatus =
  | 'queued'
  | 'extracting'
  | 'summarizing'
  | 'completed'
  | 'skipped'
  | 'failed';

interface AgentJobSource {
  url: string;
  status: AgentSourceStatus;
  entryID?: string;
  title?: string;
  error?: string;
}

interface AgentJob {
  id: string;
  topic: TopicDefinition;
  status: 'queued' | 'running' | 'completed';
  createdAt: string;
  updatedAt: string;
  sources: AgentJobSource[];
}

export interface AgentApiDependencies {
  library: LibraryService;
  extractURL(url: string): Promise<ExtractedContent | undefined>;
  processEntry(entryID: string, topicID: string): Promise<string>;
  onLibraryChanged(): Promise<void>;
  onSyncRequested(reason: string): void;
  onOperationMessage?(message: string, entryID?: string): void;
  onIngestionStarted?(): () => void;
}

export interface AgentApiConnection {
  schemaVersion: 1;
  baseURL: string;
  token: string;
  workspacePath: string;
  skill: 'briefly-deep-research';
  pid: number;
  startedAt: string;
}

class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string
  ) {
    super(message);
  }
}

export class AgentApiServer {
  private readonly token = randomBytes(32).toString('base64url');
  private readonly startedAt = new Date().toISOString();
  private readonly jobs = new Map<string, AgentJob>();
  private server: Server | null = null;
  private baseURL: string | null = null;
  private publishedWorkspacePath: string | null = null;

  constructor(
    private readonly dependencies: AgentApiDependencies,
    private readonly skillSources: BundledAgentSkill[] | string = []
  ) {}

  async start(): Promise<AgentApiConnection> {
    if (this.server && this.baseURL) return this.connection();
    this.server = createServer((request, response) => {
      void this.handle(request, response);
    });
    await new Promise<void>((resolve, reject) => {
      const server = this.server;
      if (!server) {
        reject(new Error('The agent API server could not be created.'));
        return;
      }
      server.once('error', reject);
      server.listen(0, '127.0.0.1', () => {
        server.off('error', reject);
        resolve();
      });
    });
    const address = this.server.address() as AddressInfo | null;
    if (!address) throw new Error('The agent API server did not bind to a port.');
    this.baseURL = `http://127.0.0.1:${address.port}`;
    await this.publishWorkspace();
    return this.connection();
  }

  async refreshWorkspace(previousWorkspacePath?: string): Promise<AgentApiConnection> {
    if (!this.server || !this.baseURL) {
      throw new Error('The agent API server is not running.');
    }
    if (previousWorkspacePath) {
      await this.removeConnection(previousWorkspacePath);
    } else if (this.publishedWorkspacePath) {
      await this.removeConnection(this.publishedWorkspacePath);
    }
    await this.publishWorkspace();
    return this.connection();
  }

  async stop(): Promise<void> {
    if (this.publishedWorkspacePath) {
      await this.removeConnection(this.publishedWorkspacePath);
    }
    const server = this.server;
    this.server = null;
    this.baseURL = null;
    if (!server) return;
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }

  private connection(): AgentApiConnection {
    if (!this.baseURL) throw new Error('The agent API server is not running.');
    return {
      schemaVersion: apiVersion,
      baseURL: this.baseURL,
      token: this.token,
      workspacePath: this.dependencies.library.getWorkspacePath(),
      skill: 'briefly-deep-research',
      pid: process.pid,
      startedAt: this.startedAt
    };
  }

  private async publishWorkspace(): Promise<void> {
    const workspacePath = this.dependencies.library.getWorkspacePath();
    await this.dependencies.library.ensureWorkspace();
    const skillSources =
      typeof this.skillSources === 'string'
        ? [
            {
              name: 'briefly-deep-research',
              sourcePath: this.skillSources
            }
          ]
        : this.skillSources;
    if (skillSources.length > 0) {
      await rm(join(workspacePath, legacyInstalledSkillRelativePath), {
        recursive: true,
        force: true
      });
      for (const skill of skillSources) {
        if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(skill.name)) {
          throw new Error(`Invalid bundled agent skill name: ${skill.name}`);
        }
        const installedPath = join(
          workspacePath,
          '.agents',
          'skills',
          skill.name
        );
        await mkdir(dirname(installedPath), { recursive: true });
        await cp(skill.sourcePath, installedPath, {
          recursive: true,
          force: true
        });
      }
    }
    const path = join(workspacePath, connectionRelativePath);
    await mkdir(dirname(path), { recursive: true });
    const temporaryPath = `${path}.${randomUUID()}.tmp`;
    await writeFile(
      temporaryPath,
      `${JSON.stringify(this.connection(), null, 2)}\n`,
      { encoding: 'utf8', mode: 0o600 }
    );
    await rename(temporaryPath, path);
    await chmod(path, 0o600).catch(() => {
      // Windows does not implement POSIX file modes.
    });
    this.publishedWorkspacePath = workspacePath;
  }

  private async removeConnection(workspacePath: string): Promise<void> {
    const path = join(workspacePath, connectionRelativePath);
    try {
      const value = JSON.parse(await readFile(path, 'utf8')) as {
        token?: unknown;
      };
      if (value.token === this.token) await unlink(path);
    } catch {
      // A missing or newer connection file must be left alone.
    }
    if (this.publishedWorkspacePath === workspacePath) {
      this.publishedWorkspacePath = null;
    }
  }

  private async handle(
    request: IncomingMessage,
    response: ServerResponse
  ): Promise<void> {
    try {
      this.authenticate(request);
      const url = new URL(request.url ?? '/', this.baseURL ?? 'http://127.0.0.1');
      const method = request.method ?? 'GET';

      if (method === 'GET' && url.pathname === '/v1/status') {
        this.send(response, 200, {
          ready: true,
          apiVersion,
          workspacePath: this.dependencies.library.getWorkspacePath()
        });
        return;
      }

      if (method === 'GET' && url.pathname === '/v1/topics') {
        this.send(response, 200, {
          topics: await this.dependencies.library.topicDefinitions()
        });
        return;
      }

      if (method === 'POST' && url.pathname === '/v1/topics') {
        const body = await readJSONBody(request);
        const title = stringProperty(body, 'title');
        const topic = await this.dependencies.library.ensureTopic(title);
        await this.dependencies.onLibraryChanged();
        this.dependencies.onSyncRequested('agent-created topic');
        this.send(response, 201, { topic });
        return;
      }

      const sourceMatch = /^\/v1\/topics\/([^/]+)\/sources$/.exec(url.pathname);
      if (method === 'POST' && sourceMatch) {
        const topic = await this.requireTopic(decodeURIComponent(sourceMatch[1]));
        const body = await readJSONBody(request);
        if (body.approved !== true) {
          throw new ApiError(
            409,
            'approval_required',
            'Set approved to true only after the user approves the exact URL list.'
          );
        }
        const urls = normalizeURLs(body.urls);
        const job = await this.createJob(topic, urls);
        this.send(response, 202, { job: publicJob(job) });
        return;
      }

      const itemsMatch = /^\/v1\/topics\/([^/]+)\/items$/.exec(url.pathname);
      if (method === 'GET' && itemsMatch) {
        const topic = await this.requireTopic(decodeURIComponent(itemsMatch[1]));
        const variant = normalizeVariant(url.searchParams.get('variant'));
        this.send(response, 200, {
          topic,
          variant,
          items: await this.topicItems(topic.id, variant)
        });
        return;
      }

      const jobMatch = /^\/v1\/jobs\/([^/]+)$/.exec(url.pathname);
      if (method === 'GET' && jobMatch) {
        const job = this.jobs.get(decodeURIComponent(jobMatch[1]));
        if (!job) throw new ApiError(404, 'job_not_found', 'That import job was not found.');
        this.send(response, 200, { job: publicJob(job) });
        return;
      }

      throw new ApiError(404, 'not_found', 'That agent API route does not exist.');
    } catch (error) {
      const normalized =
        error instanceof ApiError
          ? error
          : new ApiError(
              500,
              'internal_error',
              error instanceof Error ? error.message : 'The agent API request failed.'
            );
      this.send(response, normalized.status, {
        error: {
          code: normalized.code,
          message: normalized.message
        }
      });
    }
  }

  private authenticate(request: IncomingMessage): void {
    const authorization = request.headers.authorization ?? '';
    const prefix = 'Bearer ';
    if (!authorization.startsWith(prefix)) {
      throw new ApiError(401, 'unauthorized', 'A bearer token is required.');
    }
    const supplied = Buffer.from(authorization.slice(prefix.length));
    const expected = Buffer.from(this.token);
    if (
      supplied.length !== expected.length ||
      !timingSafeEqual(supplied, expected)
    ) {
      throw new ApiError(401, 'unauthorized', 'The bearer token is invalid.');
    }
  }

  private send(response: ServerResponse, status: number, value: unknown): void {
    const body = `${JSON.stringify(value, null, 2)}\n`;
    response.writeHead(status, {
      'Content-Type': 'application/json; charset=utf-8',
      'Content-Length': Buffer.byteLength(body),
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff'
    });
    response.end(body);
  }

  private async requireTopic(topicID: string): Promise<TopicDefinition> {
    const topic = (await this.dependencies.library.topicDefinitions()).find(
      (candidate) => candidate.id === topicID
    );
    if (!topic) throw new ApiError(404, 'topic_not_found', 'That topic was not found.');
    return topic;
  }

  private async createJob(
    topic: TopicDefinition,
    urls: string[]
  ): Promise<AgentJob> {
    const now = new Date().toISOString();
    const job: AgentJob = {
      id: randomUUID(),
      topic,
      status: 'queued',
      createdAt: now,
      updatedAt: now,
      sources: urls.map((url) => ({ url, status: 'queued' }))
    };
    const snapshot = await this.dependencies.library.snapshot();
    const existingByURL = new Map(
      snapshot.entries
        .filter((entry) => entry.topicIDs.includes(topic.id) && entry.sourceURL)
        .map((entry) => [canonicalURL(entry.sourceURL!), entry])
    );
    for (const source of job.sources) {
      const existing = existingByURL.get(canonicalURL(source.url));
      if (!existing) continue;
      source.status = 'skipped';
      source.entryID = existing.id;
      source.title = existing.title;
    }
    this.pruneJobs();
    this.jobs.set(job.id, job);
    void this.runJob(job);
    return job;
  }

  private async runJob(job: AgentJob): Promise<void> {
    job.status = 'running';
    job.updatedAt = new Date().toISOString();
    const pending = job.sources.filter((source) => source.status === 'queued');
    let nextIndex = 0;
    const worker = async (): Promise<void> => {
      for (;;) {
        const index = nextIndex;
        nextIndex += 1;
        const source = pending[index];
        if (!source) return;
        await this.runSource(job, source);
      }
    };
    await Promise.all(
      Array.from(
        { length: Math.min(jobConcurrency, pending.length) },
        () => worker()
      )
    );
    job.status = 'completed';
    job.updatedAt = new Date().toISOString();
    const failures = job.sources.filter((source) => source.status === 'failed').length;
    const completed = job.sources.filter(
      (source) => source.status === 'completed'
    ).length;
    this.dependencies.onOperationMessage?.(
      failures > 0
        ? `Agent import finished: ${completed} processed, ${failures} failed.`
        : `Agent import finished: ${completed} ${completed === 1 ? 'source' : 'sources'} processed.`
    );
  }

  private async runSource(job: AgentJob, source: AgentJobSource): Promise<void> {
    const finishIngestion = this.dependencies.onIngestionStarted?.();
    try {
      source.status = 'extracting';
      touch(job);
      const extracted = await this.dependencies.extractURL(source.url);
      if (!extracted) throw new Error('The URL did not return extractable content.');
      const captureID = await this.dependencies.library.captureText(
        source.url,
        extracted,
        [job.topic.id]
      );
      const entryID = `personal:${captureID}`;
      source.entryID = entryID;
      source.title = extracted.title;
      source.status = 'summarizing';
      touch(job);
      await this.dependencies.onLibraryChanged();
      this.dependencies.onSyncRequested('agent capture');
      await this.dependencies.processEntry(entryID, job.topic.id);
      source.status = 'completed';
      touch(job);
      await this.dependencies.onLibraryChanged();
      this.dependencies.onSyncRequested('agent summaries');
    } catch (error) {
      source.status = 'failed';
      source.error =
        error instanceof Error ? error.message : 'The source could not be imported.';
      touch(job);
    } finally {
      finishIngestion?.();
    }
  }

  private async topicItems(
    topicID: string,
    variant: LibraryVariant
  ): Promise<Array<Record<string, unknown>>> {
    const snapshot = await this.dependencies.library.snapshot();
    return Promise.all(
      snapshot.entries
        .filter((entry) => entry.topicIDs.includes(topicID))
        .map(async (entry) => {
          const available = entry.availableVariants.includes(variant);
          const jobSource = this.latestJobSource(entry.id);
          let status: 'ready' | 'processing' | 'failed' | 'source-only' = 'ready';
          if (!available) {
            if (jobSource?.status === 'failed') status = 'failed';
            else if (
              jobSource &&
              !['completed', 'skipped'].includes(jobSource.status)
            ) {
              status = 'processing';
            } else {
              status = 'source-only';
            }
          }
          return {
            entryID: entry.id,
            captureID: entry.captureID,
            title: entry.title,
            sourceURL: entry.sourceURL,
            status,
            availableVariants: entry.availableVariants,
            text: available
              ? await this.dependencies.library.readText(entry.id, variant)
              : null,
            error: jobSource?.error
          };
        })
    );
  }

  private latestJobSource(entryID: string): AgentJobSource | undefined {
    return [...this.jobs.values()]
      .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt))
      .flatMap((job) => job.sources)
      .find((source) => source.entryID === entryID);
  }

  private pruneJobs(): void {
    const jobs = [...this.jobs.values()].sort((left, right) =>
      right.createdAt.localeCompare(left.createdAt)
    );
    for (const job of jobs.slice(100)) this.jobs.delete(job.id);
  }
}

async function readJSONBody(
  request: IncomingMessage
): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += buffer.length;
    if (size > maximumBodyBytes) {
      throw new ApiError(413, 'body_too_large', 'The request body is too large.');
    }
    chunks.push(buffer);
  }
  try {
    const value = JSON.parse(Buffer.concat(chunks).toString('utf8')) as unknown;
    if (!value || typeof value !== 'object' || Array.isArray(value)) {
      throw new Error();
    }
    return value as Record<string, unknown>;
  } catch {
    throw new ApiError(400, 'invalid_json', 'The request body must be a JSON object.');
  }
}

function stringProperty(value: Record<string, unknown>, key: string): string {
  const result = value[key];
  if (typeof result !== 'string' || !result.trim()) {
    throw new ApiError(400, 'invalid_request', `${key} must be a non-empty string.`);
  }
  return result;
}

function normalizeURLs(value: unknown): string[] {
  if (!Array.isArray(value) || value.length === 0) {
    throw new ApiError(400, 'invalid_urls', 'urls must be a non-empty array.');
  }
  if (value.length > maximumURLsPerJob) {
    throw new ApiError(
      400,
      'too_many_urls',
      `At most ${maximumURLsPerJob} URLs can be imported at once.`
    );
  }
  const urls = value.map((candidate) => {
    if (typeof candidate !== 'string' || candidate.length > 4096) {
      throw new ApiError(400, 'invalid_url', 'Every URL must be a valid web URL.');
    }
    try {
      const url = new URL(candidate);
      if (
        (url.protocol !== 'http:' && url.protocol !== 'https:') ||
        url.username ||
        url.password
      ) {
        throw new Error();
      }
      url.hash = '';
      return url.toString();
    } catch {
      throw new ApiError(400, 'invalid_url', `Invalid web URL: ${candidate}`);
    }
  });
  return [...new Set(urls)];
}

function normalizeVariant(value: string | null): LibraryVariant {
  const variant = value ?? 'detailed';
  if (!libraryVariants.includes(variant as LibraryVariant)) {
    throw new ApiError(
      400,
      'invalid_variant',
      `variant must be one of: ${libraryVariants.join(', ')}.`
    );
  }
  return variant as LibraryVariant;
}

function canonicalURL(value: string): string {
  try {
    const url = new URL(value);
    url.hash = '';
    return url.toString();
  } catch {
    return createHash('sha256').update(value).digest('hex');
  }
}

function touch(job: AgentJob): void {
  job.updatedAt = new Date().toISOString();
}

function publicJob(job: AgentJob): Record<string, unknown> {
  const counts = {
    queued: 0,
    extracting: 0,
    summarizing: 0,
    completed: 0,
    skipped: 0,
    failed: 0
  };
  for (const source of job.sources) counts[source.status] += 1;
  return {
    id: job.id,
    topic: job.topic,
    status: job.status,
    createdAt: job.createdAt,
    updatedAt: job.updatedAt,
    counts,
    sources: job.sources
  };
}
