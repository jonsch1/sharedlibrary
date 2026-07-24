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
        const body =
          url.pathname === '/api/auth/status'
            ? { authenticated: false }
            : { error: 'Unavailable in the Electron smoke test.' };
        return new Response(JSON.stringify(body), {
          status: url.pathname === '/api/auth/status' ? 200 : 401,
          headers: { 'content-type': 'application/json' }
        });
      }

      return fetchFromNetwork(input, init);
    }
  });
});

await import('./out/main/index.js');
