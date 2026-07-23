import {
	parseLibraryProjection,
	saveLibraryProjection,
	type LibraryProjection
} from '$lib/library.js';

export interface GitHubConnection {
	connected: boolean;
	clientID?: string;
	login?: string;
	repository?: string;
	defaultBranch?: string;
	connectedAt?: string;
}

export interface GitHubDeviceAuthorization {
	userCode: string;
	verificationURI: string;
	expiresIn: number;
	interval: number;
}

interface GitHubDevicePollResult {
	state: 'pending' | 'connected' | 'expired' | 'failed';
	login?: string;
	retryAfter?: number;
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

export async function loadGitHubConnection(): Promise<GitHubConnection> {
	const response = await fetch('/api/github/status', {
		headers: { Accept: 'application/json' },
		cache: 'no-store'
	});
	if (response.status === 401 || response.status === 404) return { connected: false };
	if (!response.ok) {
		throw new Error(await errorMessage(response, 'Could not read the GitHub connection.'));
	}
	return (await response.json()) as GitHubConnection;
}

export async function beginGitHubConnection(
	clientID: string
): Promise<GitHubDeviceAuthorization> {
	const response = await fetch('/api/github/connect/start', {
		method: 'POST',
		headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
		body: JSON.stringify({ clientID })
	});
	if (!response.ok) {
		throw new Error(await errorMessage(response, 'Could not start GitHub authorization.'));
	}
	return (await response.json()) as GitHubDeviceAuthorization;
}

export async function pollGitHubConnection(): Promise<GitHubDevicePollResult> {
	const response = await fetch('/api/github/connect/poll', {
		method: 'POST',
		headers: { Accept: 'application/json' }
	});
	if (response.status === 404 || response.status === 410) return { state: 'expired' };
	const value = (await response.json()) as GitHubDevicePollResult & { error?: string };
	if (!response.ok) throw new Error(value.error || 'GitHub authorization failed.');
	return value;
}

export async function disconnectGitHub(): Promise<void> {
	const response = await fetch('/api/github/disconnect', {
		method: 'POST',
		headers: { Accept: 'application/json' }
	});
	if (!response.ok) {
		throw new Error(await errorMessage(response, 'Could not disconnect GitHub.'));
	}
}

export async function configureGitHubRepository(repository: string): Promise<GitHubConnection> {
	const response = await fetch('/api/github/repository', {
		method: 'POST',
		headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
		body: JSON.stringify({ repository })
	});
	if (!response.ok) {
		throw new Error(await errorMessage(response, 'Could not open the GitHub repository.'));
	}
	return (await response.json()) as GitHubConnection;
}

export async function syncGitHubLibrary(): Promise<LibraryProjection> {
	const response = await fetch('/api/library', {
		headers: { Accept: 'application/json' },
		cache: 'no-store'
	});
	if (!response.ok) {
		throw new Error(await errorMessage(response, 'Could not sync the library from GitHub.'));
	}
	const projection = parseLibraryProjection(await response.json());
	await saveLibraryProjection(projection);
	return projection;
}
