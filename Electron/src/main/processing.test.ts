import assert from 'node:assert/strict';
import test from 'node:test';
import {
  defaultAgentCommand,
  defaultProcessingCommand,
  defaultProcessingPrompt,
  ensureAgentWorkspacePlaceholder,
  managedAICommand,
  processingCommandPresets,
  renderAgentCommand,
  renderProcessingPrompt,
  runAIText
} from './processing.js';

test('uses Briefly AI by default without listing it as a command preset', () => {
  assert.equal(defaultProcessingCommand, managedAICommand);
  assert.equal(
    processingCommandPresets.some(({ command }) => command === managedAICommand),
    false
  );
});

test('agent commands expose and substitute the workspace placeholder', () => {
  assert.equal(
    ensureAgentWorkspacePlaceholder('claude'),
    process.platform === 'win32'
      ? 'cd /d {{workspace}} && claude'
      : 'cd {{workspace}} && claude'
  );
  assert.match(defaultAgentCommand, /\{\{workspace\}\}/);
  assert.doesNotMatch(
    renderAgentCommand(defaultAgentCommand, "/tmp/Briefly user's library"),
    /\{\{workspace\}\}/
  );
});

test('renders the editable processing template with topics and source content', () => {
  const prompt = renderProcessingPrompt(defaultProcessingPrompt, {
    title: 'Example',
    sourceURL: 'https://example.com',
    sourceText: 'Captured source text.',
    topics: ['Research Practice', 'New Methods']
  });

  assert.match(prompt, /"Research Practice"/);
  assert.match(prompt, /"source_text": "Captured source text\."/);
  assert.doesNotMatch(prompt, /\{\{topics\}\}|\{\{source\}\}/);
});

test('requires both processing-template placeholders', () => {
  assert.throws(
    () =>
      renderProcessingPrompt('Summarize {{source}}', {
        title: 'Example',
        sourceText: 'Text',
        topics: []
      }),
    /\{\{topics\}\}/
  );
});

test('custom processing commands receive the prompt on standard input', async () => {
  const command = `${JSON.stringify(process.execPath)} -e "process.stdin.pipe(process.stdout)"`;
  assert.equal(await runAIText('Custom command prompt.', command), 'Custom command prompt.');
});
