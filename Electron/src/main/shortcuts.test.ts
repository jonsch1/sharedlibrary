import assert from 'node:assert/strict';
import test from 'node:test';

import {
  captureShortcutFromKeyboardEvent,
  defaultCaptureShortcut,
  formatCaptureShortcut,
  normalizeCaptureShortcut
} from '../shared/shortcuts.js';

test('normalizes supported capture accelerators and rejects unsafe bare keys', () => {
  assert.equal(normalizeCaptureShortcut('Control+Shift+g'), 'Control+Shift+G');
  assert.equal(normalizeCaptureShortcut(defaultCaptureShortcut), defaultCaptureShortcut);
  assert.equal(normalizeCaptureShortcut('G'), null);
  assert.equal(normalizeCaptureShortcut('Shift+G'), null);
  assert.equal(normalizeCaptureShortcut('Control+MediaPlayPause'), null);
});

test('creates platform-specific accelerators from keyboard events', () => {
  assert.equal(
    captureShortcutFromKeyboardEvent(
      {
        code: 'KeyK',
        key: 'k',
        metaKey: true,
        ctrlKey: false,
        altKey: false,
        shiftKey: true
      },
      'darwin'
    ),
    'Command+Shift+K'
  );
  assert.equal(
    captureShortcutFromKeyboardEvent(
      {
        code: 'Digit7',
        key: '7',
        metaKey: false,
        ctrlKey: true,
        altKey: true,
        shiftKey: false
      },
      'win32'
    ),
    'Control+Alt+7'
  );
});

test('formats shortcuts for the current desktop platform', () => {
  assert.equal(formatCaptureShortcut(defaultCaptureShortcut, 'darwin'), '⌘G');
  assert.equal(formatCaptureShortcut(defaultCaptureShortcut, 'win32'), 'Ctrl+G');
  assert.equal(formatCaptureShortcut('Command+Shift+K', 'darwin'), '⌘⇧K');
});
