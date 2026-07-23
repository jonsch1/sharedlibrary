export interface GoogleDriveConnection {
	configured: boolean;
	connected: boolean;
	clientID?: string;
	connectedAt?: string;
	callbackURL?: string;
}

async function errorMessage(response: Response, fallback: string): Promise<string> {
	try {
		const value = (await response.json()) as { error?: string; message?: string };
		if (typeof value.error === 'string') return value.error;
		if (typeof value.message === 'string') return value.message;
	} catch {
		// The response was not JSON.
	}
	return fallback;
}

export async function loadGoogleDriveConnection(): Promise<GoogleDriveConnection> {
	const response = await fetch('/api/google/status', {
		headers: { Accept: 'application/json' },
		cache: 'no-store'
	});
	if (response.status === 401 || response.status === 404) {
		return { configured: false, connected: false };
	}
	if (!response.ok) {
		throw new Error(await errorMessage(response, 'Could not read the Google Drive connection.'));
	}
	return (await response.json()) as GoogleDriveConnection;
}

export async function configureGoogleDrive(
	clientID: string,
	clientSecret: string
): Promise<void> {
	const response = await fetch('/api/google/configure', {
		method: 'POST',
		headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
		body: JSON.stringify({ clientID, clientSecret })
	});
	if (!response.ok) {
		throw new Error(await errorMessage(response, 'Could not save the Google OAuth client.'));
	}
}

export function beginGoogleDriveConnection(): void {
	window.location.assign('/api/google/connect/start');
}

export function consumeGoogleDriveConnectionResult(): string | null {
	const url = new URL(window.location.href);
	const result = url.searchParams.get('google');
	if (!result) return null;
	url.searchParams.delete('google');
	window.history.replaceState({}, '', `${url.pathname}${url.search}${url.hash}`);
	return result;
}

export async function disconnectGoogleDrive(): Promise<void> {
	const response = await fetch('/api/google/disconnect', {
		method: 'POST',
		headers: { Accept: 'application/json' }
	});
	if (!response.ok) {
		throw new Error(await errorMessage(response, 'Could not disconnect Google Drive.'));
	}
}

export async function loadGoogleDriveAudio(hash: string): Promise<Blob | null> {
	const response = await fetch(`/api/media/audio/${hash}`);
	if (response.status === 401 || response.status === 404) return null;
	if (!response.ok) return null;
	return response.blob();
}

export async function storeGoogleDriveAudio(hash: string, audio: Blob): Promise<void> {
	const response = await fetch(`/api/media/audio/${hash}`, {
		method: 'PUT',
		headers: { 'Content-Type': audio.type || 'audio/mpeg' },
		body: audio
	});
	if (response.status === 401 || response.status === 404) return;
	if (!response.ok) {
		throw new Error(await errorMessage(response, 'Could not save audio to Google Drive.'));
	}
}
