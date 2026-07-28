import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

import { resolveThemeStyle, themeOptions } from '../../../Shared/themes.js';

test('ships every TweakCN preset and inherits optional light tokens in dark mode', () => {
  assert.equal(themeOptions.length, 42);
  assert.equal(new Set(themeOptions.map(({ value }) => value)).size, 42);
  assert.equal(themeOptions.at(0)?.value, 'modern-minimal');
  assert.equal(themeOptions.at(-1)?.value, 'sage-garden');
  assert.equal(
    resolveThemeStyle('modern-minimal', 'dark')['font-sans'],
    '"Inter Variable", sans-serif'
  );
  assert.equal(
    resolveThemeStyle('pastel-dreams', 'light')['font-serif'],
    '"Source Serif 4 Variable", serif'
  );
  assert.equal(resolveThemeStyle('vercel', 'system', true).background, 'oklch(0 0 0)');
  assert.equal(resolveThemeStyle('neo-brutalism', 'light').radius, '0px');
  assert.equal(resolveThemeStyle('neo-brutalism', 'light')['shadow-offset-x'], '4px');
  assert.equal(
    resolveThemeStyle('neo-brutalism', 'light')['shadow-sm'],
    '4px 4px 0px 0px color-mix(in srgb, hsl(0 0% 0%) 100%, transparent)'
  );
});

test('theme surfaces use semantic colors only', async () => {
  const files = [
    '../renderer/App.svelte',
    '../renderer/PodcastsView.svelte',
    '../../../Shared/AudioPlayer.svelte',
    '../../../Shared/DepthControl.svelte',
    '../../../Shared/MarkdownView.svelte',
    '../../../Web/src/lib/PublicShareReader.svelte',
    '../../../Web/src/routes/+page.svelte'
  ];
  const literalColor =
    /#[\da-f]{3,8}\b|\brgba?\(|\bhsla?\(|\b(?:bg|text|border|ring)-(?:black|white|slate|gray|zinc|neutral|stone|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose)(?:[-/!]|\b)/i;

  for (const file of files) {
    const source = await readFile(new URL(file, import.meta.url), 'utf8');
    assert.doesNotMatch(source, literalColor, file);
  }
});
