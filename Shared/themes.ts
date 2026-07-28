import tweakcnThemes from './tweakcn-themes.json' with { type: 'json' };

type ThemeStyle = Record<string, string>;
type ThemePreset = {
  label: string;
  styles: { light: ThemeStyle; dark: ThemeStyle };
};

// TweakCN built-in presets, retrieved from
// https://github.com/jnsahaj/tweakcn/blob/main/utils/theme-presets.ts
export const themes = tweakcnThemes satisfies Record<string, ThemePreset>;

export type ThemeName = keyof typeof themes;
export type ThemeMode = 'light' | 'dark' | 'system';
export type ThemePreference = { theme: ThemeName; mode: ThemeMode };

export const themeOptions = Object.entries(themes).map(([value, preset]) => ({
  value: value as ThemeName,
  label: preset.label
}));

export const themeModeOptions: Array<{ value: ThemeMode; label: string }> = [
  { value: 'light', label: 'Light' },
  { value: 'dark', label: 'Dark' },
  { value: 'system', label: 'System' }
];

const defaultPreference: ThemePreference = { theme: 'modern-minimal', mode: 'light' };
const themeStorageKey = 'briefly-theme';
const modeStorageKey = 'briefly-theme-mode';
const variableFontFamilies = [
  'Plus Jakarta Sans',
  'Playfair Display',
  'Source Code Pro',
  'Source Serif 4',
  'JetBrains Mono',
  'Merriweather',
  'Geist Mono',
  'Roboto Mono',
  'Montserrat',
  'Open Sans',
  'Quicksand',
  'Oxanium',
  'Fira Code',
  'DM Sans',
  'Roboto',
  'Outfit',
  'Inter',
  'Geist',
  'Lora'
];

function bundledFontStack(stack: string): string {
  const comma = stack.indexOf(',');
  const primary = (comma === -1 ? stack : stack.slice(0, comma))
    .trim()
    .replace(/^(['"])(.*)\1$/, '$2');
  return variableFontFamilies.includes(primary)
    ? `"${primary} Variable"${comma === -1 ? '' : stack.slice(comma)}`
    : stack;
}

function tailwindShadow(style: ThemeStyle): string {
  const opacity = Number(style['shadow-opacity'] ?? 0);
  if (!opacity || !style['shadow-color']) return 'none';
  return `${style['shadow-offset-x'] ?? '0px'} ${style['shadow-offset-y'] ?? '0px'} ${
    style['shadow-blur'] ?? '0px'
  } ${style['shadow-spread'] ?? '0px'} color-mix(in srgb, ${
    style['shadow-color']
  } ${opacity * 100}%, transparent)`;
}

const themeTokens = [
  ...new Set(
    Object.values(themes).flatMap((preset) =>
      Object.values(preset.styles).flatMap((style) => Object.keys(style))
    )
  ),
  'shadow-sm'
];

export function resolveThemeStyle(
  theme: ThemeName,
  mode: ThemeMode,
  systemPrefersDark = false
): ThemeStyle {
  const preset = themes[theme] as ThemePreset;
  const resolvedMode = mode === 'system' ? (systemPrefersDark ? 'dark' : 'light') : mode;
  const style = resolvedMode === 'dark'
    ? { ...preset.styles.light, ...preset.styles.dark }
    : preset.styles.light;
  const bundledStyle = Object.fromEntries(
    Object.entries(style).map(([token, value]) => [
      token,
      token.startsWith('font-') ? bundledFontStack(value) : value
    ])
  );
  return { ...bundledStyle, 'shadow-sm': tailwindShadow(bundledStyle) };
}

export function readThemePreference(): ThemePreference {
  if (typeof window === 'undefined') return defaultPreference;
  try {
    const theme = window.localStorage.getItem(themeStorageKey);
    const mode = window.localStorage.getItem(modeStorageKey);
    return {
      theme: theme && theme in themes ? (theme as ThemeName) : defaultPreference.theme,
      mode: mode === 'dark' || mode === 'system' ? mode : 'light'
    };
  } catch {
    return defaultPreference;
  }
}

export function applyThemePreference(preference: ThemePreference): void {
  if (typeof document === 'undefined') return;
  const dark =
    preference.mode === 'dark' ||
    (preference.mode === 'system' && window.matchMedia('(prefers-color-scheme: dark)').matches);
  const style = resolveThemeStyle(preference.theme, dark ? 'dark' : 'light');
  const root = document.documentElement;

  const propertyName = (token: string): string =>
    `--${token.startsWith('font-') || token === 'shadow-sm' ? 'theme-' : ''}${token}`;
  for (const token of themeTokens) root.style.removeProperty(propertyName(token));
  for (const [token, value] of Object.entries(style)) {
    root.style.setProperty(propertyName(token), value);
  }

  root.classList.toggle('dark', dark);
  root.dataset.theme = preference.theme;
  root.style.colorScheme = dark ? 'dark' : 'light';
  document
    .querySelector('meta[name="theme-color"]')
    ?.setAttribute('content', style.background);
}

export function setThemePreference(preference: ThemePreference): void {
  try {
    window.localStorage.setItem(themeStorageKey, preference.theme);
    window.localStorage.setItem(modeStorageKey, preference.mode);
  } catch {
    // The theme still applies for this session when storage is unavailable.
  }
  applyThemePreference(preference);
}

export function initializeTheme(): () => void {
  const media = window.matchMedia('(prefers-color-scheme: dark)');
  const refresh = (): void => applyThemePreference(readThemePreference());
  refresh();
  media.addEventListener('change', refresh);
  return () => media.removeEventListener('change', refresh);
}
