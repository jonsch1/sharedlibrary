export interface GoogleDriveConnection {
	configured: boolean;
	connected: boolean;
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
	if (response.status === 401) {
		try {
			const value = (await response.json()) as { configured?: unknown };
			return { configured: value.configured === true, connected: false };
		} catch {
			return { configured: true, connected: false };
		}
	}
	if (response.status === 404) {
		return { configured: false, connected: false };
	}
	if (!response.ok) {
		throw new Error(await errorMessage(response, 'Could not read the Google Drive connection.'));
	}
	return (await response.json()) as GoogleDriveConnection;
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

export async function syncGoogleDriveLibrary(
	onProjectionAvailable?: (projection: LibraryProjection) => void,
	onProgress?: (completed: number, total: number) => void
): Promise<LibraryProjection> {
	const response = await fetch('/api/library', {
		headers: { Accept: 'application/json' },
		cache: 'no-store'
	});
	if (!response.ok) {
		throw new Error(
			await errorMessage(response, 'Could not sync the library from Google Drive.')
		);
	}
	const projection = parseLibraryProjection(await response.json());
	onProjectionAvailable?.(projection);
	await mirrorLibraryProjection(projection, (progress) =>
		onProgress?.(progress.completed, progress.total)
	);
	return projection;
}

import {
	mirrorLibraryProjection,
	parseLibraryProjection,
	type LibraryProjection
} from '$lib/library.js';
