import { app, session } from 'electron';

const userDataPath = (
  process.env.BRIEFLY_E2E_USER_DATA ??
  process.env.SHARED_LIBRARY_E2E_USER_DATA
)?.trim();
if (!userDataPath) {
  throw new Error('BRIEFLY_E2E_USER_DATA must point to an isolated directory.');
}

app.setPath('userData', userDataPath);

app.once('ready', () => {
  const defaultSession = session.defaultSession;
  const fetchFromNetwork = defaultSession.fetch.bind(defaultSession);

  Object.defineProperty(defaultSession, 'fetch', {
    configurable: true,
    value: async (input, init) => {
      const requestURL =
        typeof input === 'string'
          ? input
          : input instanceof URL
            ? input.toString()
            : input.url;
      const url = new URL(requestURL);

      if (
        url.origin ===
        'https://www.readbriefly.fyi'
      ) {
        const body = {
          '/api/auth/status': {
            authenticated: true,
            email: 'schauljonathan@gmail.com'
          },
          '/api/google/status': { configured: true, connected: false },
          '/api/billing/status': { entitled: true, complimentary: true }
        }[url.pathname] ?? { error: 'Unavailable in the Electron smoke test.' };
        return new Response(JSON.stringify(body), {
          status: 'error' in body ? 401 : 200,
          headers: { 'content-type': 'application/json' }
        });
      }

      return fetchFromNetwork(input, init);
    }
  });
});

await import('./out/main/index.js');
