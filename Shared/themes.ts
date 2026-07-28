import tweakcnThemes from './tweakcn-themes.json' with { type: 'json' };

type ThemeStyle = Record<string, string>;
type ThemePreset = {
  label: string;
  styles: { light: ThemeStyle; dark: ThemeStyle };
};

const brieflyTheme = {
  label: 'Briefly',
  styles: {
    light: {
      background: 'rgb(176 178 173)',
      foreground: 'rgb(31 31 29)',
      card: 'rgb(232 230 219)',
      'card-foreground': 'rgb(31 31 29)',
      popover: 'rgb(235 233 223)',
      'popover-foreground': 'rgb(31 31 29)',
      primary: 'rgb(120 122 117)',
      'primary-foreground': 'rgb(250 249 244)',
      secondary: 'rgb(221 221 212)',
      'secondary-foreground': 'rgb(51 51 47)',
      muted: 'rgb(224 223 214)',
      'muted-foreground': 'rgb(92 92 85)',
      accent: 'rgb(202 202 193)',
      'accent-foreground': 'rgb(39 39 36)',
      destructive: 'oklch(0.577 0.245 27.325)',
      'destructive-foreground': 'white',
      border: 'rgb(46 46 43 / 38%)',
      input: 'rgb(46 46 43 / 42%)',
      ring: 'rgb(92 94 89)',
      'chart-1': 'oklch(0.87 0 0)',
      'chart-2': 'oklch(0.556 0 0)',
      'chart-3': 'oklch(0.439 0 0)',
      'chart-4': 'oklch(0.371 0 0)',
      'chart-5': 'oklch(0.269 0 0)',
      radius: '0.85rem',
      'shadow-color': 'rgb(0 0 0)',
      'shadow-opacity': '0.1',
      'shadow-blur': '3px',
      'shadow-spread': '0px',
      'shadow-offset-x': '0px',
      'shadow-offset-y': '1px',
      sidebar: 'rgb(209 209 201)',
      'sidebar-foreground': 'rgb(31 31 29)',
      'sidebar-primary': 'rgb(120 122 117)',
      'sidebar-primary-foreground': 'rgb(250 249 244)',
      'sidebar-accent': 'rgb(198 198 189)',
      'sidebar-accent-foreground': 'rgb(31 31 29)',
      'sidebar-border': 'rgb(46 46 43 / 38%)',
      'sidebar-ring': 'rgb(92 94 89)',
      'font-sans':
        '-apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif',
      'font-serif': '"New York", "Iowan Old Style", Charter, Georgia, serif',
      'font-mono': 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace'
    },
    dark: {
      background: 'oklch(0.145 0 0)',
      foreground: 'oklch(0.985 0 0)',
      card: 'oklch(0.205 0 0)',
      'card-foreground': 'oklch(0.985 0 0)',
      popover: 'oklch(0.205 0 0)',
      'popover-foreground': 'oklch(0.985 0 0)',
      primary: 'oklch(0.922 0 0)',
      'primary-foreground': 'oklch(0.205 0 0)',
      secondary: 'oklch(0.269 0 0)',
      'secondary-foreground': 'oklch(0.985 0 0)',
      muted: 'oklch(0.269 0 0)',
      'muted-foreground': 'oklch(0.708 0 0)',
      accent: 'oklch(0.269 0 0)',
      'accent-foreground': 'oklch(0.985 0 0)',
      destructive: 'oklch(0.704 0.191 22.216)',
      border: 'oklch(1 0 0 / 10%)',
      input: 'oklch(1 0 0 / 15%)',
      ring: 'oklch(0.556 0 0)',
      sidebar: 'oklch(0.205 0 0)',
      'sidebar-foreground': 'oklch(0.985 0 0)',
      'sidebar-primary': 'oklch(0.488 0.243 264.376)',
      'sidebar-primary-foreground': 'oklch(0.985 0 0)',
      'sidebar-accent': 'oklch(0.269 0 0)',
      'sidebar-accent-foreground': 'oklch(0.985 0 0)',
      'sidebar-border': 'oklch(1 0 0 / 10%)',
      'sidebar-ring': 'oklch(0.556 0 0)'
    }
  }
} satisfies ThemePreset;

// TweakCN built-in presets, retrieved from
// https://github.com/jnsahaj/tweakcn/blob/main/utils/theme-presets.ts
export const themes = {
  briefly: brieflyTheme,
  ...tweakcnThemes
} satisfies Record<string, ThemePreset>;

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

const defaultPreference: ThemePreference = { theme: 'briefly', mode: 'light' };
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
