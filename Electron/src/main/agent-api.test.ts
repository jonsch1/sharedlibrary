import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { AgentApiServer, type AgentApiConnection } from './agent-api.js';
import { LibraryService, type ProcessingSuggestion } from './library.js';

const fakeSuggestion: ProcessingSuggestion = {
  shortFilename: 'approved-research-source',
  topicName: 'Ignored automatic topic',
  summaries: {
    brief: 'Brief approved summary.',
    concise: 'Concise approved summary.',
    detailed: 'Detailed approved summary.',
    comprehensive: 'Comprehensive approved summary.'
  }
};

test('agent API requires approval, imports URLs, and returns topic summaries', async () => {
  const root = await mkdtemp(join(tmpdir(), 'shared-library-agent-api-'));
  const workspace = join(root, 'workspace');
  const researchSkillSource = join(root, 'research-skill-source');
  const inputSkillSource = join(root, 'input-skill-source');
  await mkdir(researchSkillSource, { recursive: true });
  await mkdir(inputSkillSource, { recursive: true });
  await writeFile(
    join(researchSkillSource, 'SKILL.md'),
    '---\nname: test\n---\n'
  );
  await writeFile(
    join(inputSkillSource, 'SKILL.md'),
    '---\nname: input-test\n---\n'
  );
  const legacySkillPath = join(
    workspace,
    '.agents',
    'skills',
    'shared-library-deep-research'
  );
  await mkdir(legacySkillPath, { recursive: true });
  await writeFile(join(legacySkillPath, 'SKILL.md'), 'legacy');
  const library = new LibraryService(
    workspace,
    'linux',
    (path) => rm(path, { force: true })
  );
  const syncReasons: string[] = [];
  let activeIngestions = 0;
  let completedIngestions = 0;
  const server = new AgentApiServer(
    {
      library,
      extractURL: async (url) => ({
        title: new URL(url).hostname,
        content: `Extracted content from ${url}`,
        sourceURL: url
      }),
      processEntry: (entryID, topicID) =>
        library.applyProcessingSuggestion(entryID, fakeSuggestion, topicID),
      onLibraryChanged: async () => {
        await library.snapshot();
      },
      onSyncRequested: (reason) => syncReasons.push(reason),
      onIngestionStarted: () => {
        activeIngestions += 1;
        return () => {
          activeIngestions -= 1;
          completedIngestions += 1;
        };
      }
    },
    [
      {
        name: 'briefly-deep-research',
        sourcePath: researchSkillSource
      },
      {
        name: 'briefly-input-extension',
        sourcePath: inputSkillSource
      }
    ]
  );

  try {
    const connection = await server.start();
    const configPath = join(workspace, '.shared-library', 'agent-api.json');
    const config = JSON.parse(await readFile(configPath, 'utf8')) as AgentApiConnection;
    assert.equal(config.baseURL, connection.baseURL);
    assert.equal(config.token, connection.token);
    assert.equal(config.skill, 'briefly-deep-research');
    if (process.platform !== 'win32') {
      assert.equal((await stat(configPath)).mode & 0o777, 0o600);
    }
    assert.match(
      await readFile(
        join(
          workspace,
          '.agents',
          'skills',
          'briefly-deep-research',
          'SKILL.md'
        ),
        'utf8'
      ),
      /name: test/
    );
    assert.match(
      await readFile(
        join(
          workspace,
          '.agents',
          'skills',
          'briefly-input-extension',
          'SKILL.md'
        ),
        'utf8'
      ),
      /name: input-test/
    );
    await assert.rejects(stat(legacySkillPath));

    const unauthorized = await fetch(`${connection.baseURL}/v1/status`);
    assert.equal(unauthorized.status, 401);

    const created = await api(connection, 'POST', '/v1/topics', {
      title: 'Battery Recycling'
    });
    assert.equal(created.response.status, 201);
    assert.deepEqual(created.value.topic, {
      id: 'battery-recycling',
      title: 'Battery Recycling'
    });

    const rejected = await api(
      connection,
      'POST',
      '/v1/topics/battery-recycling/sources',
      {
        approved: false,
        urls: ['https://example.com/report']
      }
    );
    assert.equal(rejected.response.status, 409);
    assert.equal(rejected.value.error.code, 'approval_required');
    assert.equal((await library.snapshot()).entries.length, 0);

    const accepted = await api(
      connection,
      'POST',
      '/v1/topics/battery-recycling/sources',
      {
        approved: true,
        urls: [
          'https://example.com/report#overview',
          'https://example.org/analysis'
        ]
      }
    );
    assert.equal(accepted.response.status, 202);
    const jobID = String(accepted.value.job.id);
    const completed = await waitForJob(connection, jobID);
    assert.equal(completed.job.status, 'completed');
    assert.equal(completed.job.counts.completed, 2);
    assert.equal(completed.job.counts.failed, 0);

    const items = await api(
      connection,
      'GET',
      '/v1/topics/battery-recycling/items?variant=detailed'
    );
    assert.equal(items.response.status, 200, JSON.stringify(items.value));
    assert.equal(items.value.items.length, 2);
    for (const item of items.value.items) {
      assert.equal(item.status, 'ready');
      assert.equal(item.text, 'Detailed approved summary.');
    }
    assert.deepEqual(
      (await library.snapshot()).entries.map((entry) => entry.topicIDs),
      [['battery-recycling'], ['battery-recycling']]
    );
    assert.ok(syncReasons.includes('agent capture'));
    assert.ok(syncReasons.includes('agent summaries'));
    assert.equal(activeIngestions, 0);
    assert.equal(completedIngestions, 2);

    const duplicate = await api(
      connection,
      'POST',
      '/v1/topics/battery-recycling/sources',
      {
        approved: true,
        urls: ['https://example.com/report']
      }
    );
    const duplicateJob = await waitForJob(
      connection,
      String(duplicate.value.job.id)
    );
    assert.equal(duplicateJob.job.counts.skipped, 1);
    assert.equal((await library.snapshot()).entries.length, 2);

    await server.stop();
    await assert.rejects(readFile(configPath, 'utf8'));
  } finally {
    await server.stop();
    await rm(root, { recursive: true, force: true });
  }
});

async function api(
  connection: AgentApiConnection,
  method: string,
  path: string,
  body?: Record<string, unknown>
): Promise<{ response: Response; value: any }> {
  const response = await fetch(`${connection.baseURL}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${connection.token}`,
      ...(body ? { 'Content-Type': 'application/json' } : {})
    },
    body: body ? JSON.stringify(body) : undefined
  });
  return {
    response,
    value: await response.json()
  };
}

async function waitForJob(
  connection: AgentApiConnection,
  jobID: string
): Promise<any> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const result = await api(connection, 'GET', `/v1/jobs/${jobID}`);
    if (result.value.job.status === 'completed') return result.value;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error('Agent API job did not complete.');
}
