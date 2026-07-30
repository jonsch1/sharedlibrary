import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import { AgentApiServer, type AgentApiConnection } from './agent-api.js';
import { ItemService } from './items.js';
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
  const audioSkillSource = join(root, 'audio-skill-source');
  await mkdir(researchSkillSource, { recursive: true });
  await mkdir(inputSkillSource, { recursive: true });
  await mkdir(audioSkillSource, { recursive: true });
  await writeFile(
    join(researchSkillSource, 'SKILL.md'),
    '---\nname: test\n---\n'
  );
  await writeFile(
    join(inputSkillSource, 'SKILL.md'),
    '---\nname: input-test\n---\n'
  );
  await writeFile(
    join(audioSkillSource, 'SKILL.md'),
    '---\nname: audio-test\n---\n'
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
  const createdEpisodes: Array<Record<string, unknown>> = [];
  let activeIngestions = 0;
  let completedIngestions = 0;
  const extractURL = async (url: string) => ({
    title: new URL(url).hostname,
    content: `Extracted content from ${url}`,
    sourceURL: url,
    audio: {
      bytes: new Uint8Array([1, 2, 3]),
      extension: 'm4a' as const
    }
  });
  const items = new ItemService(
    library,
    { extractURL },
    {
      process: (entryID, _library, topicID) =>
        library.applyProcessingSuggestion(entryID, fakeSuggestion, topicID)
    },
    () => library.snapshot(),
    (reason) => syncReasons.push(reason)
  );
  const server = new AgentApiServer(
    {
      library,
      extractURL,
      saveItem: (url, options) => items.save(url, options),
      processItem: (entryID, topicID, reason) =>
        items.process(entryID, topicID, reason),
      podcastSnapshot: async () => ({
        generatedAt: new Date().toISOString(),
        maximumPodcasts: 20,
        channels: [],
        podcasts: [
          {
            id: 'file:daily-ai.md',
            filename: 'daily-ai.md',
            title: 'Daily AI',
            prompt: 'Focus on practical changes.',
            prioritizeForMe: false,
            schedule: 'manual',
            length: '',
            sources: ['https://x.com/openai'],
            status: 'idle',
            message: 'Ready.',
            episodes: [
              {
                id: 'personal:episode-1',
                captureID: 'episode-1',
                entryType: 'podcast_episode',
                podcastID: 'file:daily-ai.md',
                filename: 'daily-ai-episode.md',
                title: 'Daily AI episode',
                excerpt: 'Episode.',
                topicIDs: [],
                topicNames: [],
                tags: ['podcast'],
                sourceURLs: ['https://x.com/openai/status/123'],
                createdAt: '2026-07-29T08:00:00.000Z',
                hasAudio: true,
                availableVariants: ['source']
              }
            ],
            sourceStatuses: []
          }
        ]
      }),
      createPodcastEpisode: async (podcastID, script, sources) => {
        createdEpisodes.push({ podcastID, script, sources });
        return {
          entryID: 'personal:agent-episode',
          duplicate: false,
          audioPending: true
        };
      },
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
      },
      {
        name: 'briefly-audio-briefing',
        sourcePath: audioSkillSource
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
    assert.match(
      await readFile(
        join(
          workspace,
          '.agents',
          'skills',
          'briefly-audio-briefing',
          'SKILL.md'
        ),
        'utf8'
      ),
      /name: audio-test/
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
    assert.ok((await library.snapshot()).entries.every((entry) => !entry.hasAudio));
    assert.ok(syncReasons.includes('agent capture'));
    assert.ok(syncReasons.includes('agent summaries'));
    assert.equal(activeIngestions, 0);
    assert.equal(completedIngestions, 2);

    const podcasts = await api(connection, 'GET', '/v1/podcasts');
    assert.equal(podcasts.value.podcasts[0].id, 'file:daily-ai.md');
    assert.deepEqual(podcasts.value.podcasts[0].usedItemKeys, ['x:status:123']);

    const extracted = await api(connection, 'POST', '/v1/extract', {
      url: 'https://example.com/update'
    });
    assert.equal(extracted.value.item.url, 'https://example.com/update');
    assert.match(extracted.value.item.content, /Extracted content/);

    const episode = await api(
      connection,
      'POST',
      '/v1/podcasts/file%3Adaily-ai.md/episodes',
      {
        script: '# Agent episode\n\nA useful update.',
        sources: [
          {
            url: 'https://x.com/openai/status/456?utm_source=test',
            title: 'OpenAI update',
            content: 'Browser-captured post.'
          }
        ]
      }
    );
    assert.equal(episode.response.status, 201);
    assert.equal(episode.value.episode.audioPending, true);
    assert.equal(createdEpisodes.length, 1);

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
