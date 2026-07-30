import type { DesktopPlatform } from './contracts.js';

export const defaultCaptureShortcut = 'CommandOrControl+G';

const modifierOrder = [
  'CommandOrControl',
  'Command',
  'Control',
  'Alt',
  'Shift',
  'Super'
] as const;
const modifierSet = new Set<string>(modifierOrder);
const namedKeys = new Set([
  'Space',
  'Tab',
  'Backspace',
  'Delete',
  'Insert',
  'Enter',
  'Up',
  'Down',
  'Left',
  'Right',
  'Home',
  'End',
  'PageUp',
  'PageDown',
  'Escape'
]);

export interface ShortcutKeyboardEvent {
  code: string;
  key: string;
  metaKey: boolean;
  ctrlKey: boolean;
  altKey: boolean;
  shiftKey: boolean;
}

export function normalizeCaptureShortcut(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const tokens = value
    .split('+')
    .map((token) => token.trim())
    .filter(Boolean);
  if (tokens.length < 2) return null;

  const key = normalizeKey(tokens.at(-1) ?? '');
  if (!key) return null;
  const modifiers = [...new Set(tokens.slice(0, -1))];
  if (
    modifiers.some((modifier) => !modifierSet.has(modifier)) ||
    !modifiers.some((modifier) =>
      ['CommandOrControl', 'Command', 'Control', 'Alt', 'Super'].includes(modifier)
    )
  ) {
    return null;
  }

  return [
    ...modifierOrder.filter((modifier) => modifiers.includes(modifier)),
    key
  ].join('+');
}

export function captureShortcutFromKeyboardEvent(
  event: ShortcutKeyboardEvent,
  platform: DesktopPlatform
): string | null {
  const key = keyFromCode(event.code);
  if (!key || (!event.metaKey && !event.ctrlKey && !event.altKey)) return null;

  const modifiers: string[] = [];
  if (event.metaKey) modifiers.push(platform === 'darwin' ? 'Command' : 'Super');
  if (event.ctrlKey) modifiers.push('Control');
  if (event.altKey) modifiers.push('Alt');
  if (event.shiftKey) modifiers.push('Shift');
  return normalizeCaptureShortcut([...modifiers, key].join('+'));
}

export function formatCaptureShortcut(
  accelerator: string,
  platform: DesktopPlatform
): string {
  const normalized = normalizeCaptureShortcut(accelerator) ?? defaultCaptureShortcut;
  const tokens = normalized.split('+');
  const key = tokens.pop() ?? '';
  if (platform === 'darwin') {
    const symbols: Record<string, string> = {
      CommandOrControl: '⌘',
      Command: '⌘',
      Control: '⌃',
      Alt: '⌥',
      Shift: '⇧',
      Super: '⌘'
    };
    return `${tokens.map((token) => symbols[token] ?? token).join('')}${displayKey(key)}`;
  }
  const labels: Record<string, string> = {
    CommandOrControl: 'Ctrl',
    Command: 'Cmd',
    Control: 'Ctrl',
    Alt: 'Alt',
    Shift: 'Shift',
    Super: 'Super'
  };
  return [...tokens.map((token) => labels[token] ?? token), displayKey(key)].join('+');
}

function normalizeKey(value: string): string | null {
  if (/^[A-Za-z]$/.test(value)) return value.toUpperCase();
  if (/^[0-9]$/.test(value)) return value;
  if (/^F(?:[1-9]|1[0-9]|2[0-4])$/i.test(value)) return value.toUpperCase();
  const named = [...namedKeys].find(
    (candidate) => candidate.toLowerCase() === value.toLowerCase()
  );
  return named ?? null;
}

function keyFromCode(code: string): string | null {
  if (/^Key[A-Z]$/.test(code)) return code.slice(3);
  if (/^Digit[0-9]$/.test(code)) return code.slice(5);
  if (/^F(?:[1-9]|1[0-9]|2[0-4])$/.test(code)) return code;
  const codes: Record<string, string> = {
    Space: 'Space',
    Tab: 'Tab',
    Backspace: 'Backspace',
    Delete: 'Delete',
    Insert: 'Insert',
    Enter: 'Enter',
    NumpadEnter: 'Enter',
    ArrowUp: 'Up',
    ArrowDown: 'Down',
    ArrowLeft: 'Left',
    ArrowRight: 'Right',
    Home: 'Home',
    End: 'End',
    PageUp: 'PageUp',
    PageDown: 'PageDown',
    Escape: 'Escape'
  };
  return codes[code] ?? null;
}

function displayKey(key: string): string {
  const labels: Record<string, string> = {
    Up: '↑',
    Down: '↓',
    Left: '←',
    Right: '→',
    Space: 'Space'
  };
  return labels[key] ?? key;
}
