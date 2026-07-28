export function isWebURL(value: string): boolean {
  try {
    const url = new URL(value);
    return url.protocol === 'http:' || url.protocol === 'https:';
  } catch {
    return false;
  }
}

export function isTrustedRendererURL(value: string, rendererEntryURL: string): boolean {
  try {
    const candidate = new URL(value);
    const expected = new URL(rendererEntryURL);
    return (
      candidate.protocol === expected.protocol &&
      candidate.origin === expected.origin &&
      candidate.pathname === expected.pathname
    );
  } catch {
    return false;
  }
}
