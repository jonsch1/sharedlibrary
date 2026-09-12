type ThemeMode = 'light' | 'dark' | 'system';

function readThemeMode(): ThemeMode {
  try {
    const mode = window.localStorage.getItem('briefly-theme-mode');
    return mode === 'dark' || mode === 'system' ? mode : 'light';
  } catch {
    return 'light';
  }
}

export function initializeTheme(): () => void {
  const media = window.matchMedia('(prefers-color-scheme: dark)');
  const refresh = (): void => {
    const mode = readThemeMode();
    const dark = mode === 'dark' || (mode === 'system' && media.matches);
    const root = document.documentElement;
    root.classList.toggle('dark', dark);
    root.style.colorScheme = dark ? 'dark' : 'light';
    document.querySelector('meta[name="theme-color"]')?.setAttribute(
      'content', getComputedStyle(root).getPropertyValue('--background').trim()
    );
  };
  refresh();
  media.addEventListener('change', refresh);
  return () => media.removeEventListener('change', refresh);
}
