import { parseLibraryProjection, type LibraryProjection } from '$lib/library.js';

export interface SharedFolderConnection {
	connected: boolean;
	folderID?: string;
	folderName?: string;
	userID?: string;
	username?: string;
	connectedAt?: string;
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

export async function loadSharedFolderConnection(): Promise<SharedFolderConnection> {
	const response = await fetch('/api/sharing/status', {
		headers: { Accept: 'application/json' },
		cache: 'no-store'
	});
	if (response.status === 401 || response.status === 404) return { connected: false };
	if (!response.ok) {
		throw new Error(await errorMessage(response, 'Could not read the shared-folder connection.'));
	}
	return (await response.json()) as SharedFolderConnection;
}

export async function connectSharedFolder(
	folder: string,
	username: string
): Promise<SharedFolderConnection> {
	const response = await fetch('/api/sharing/connect', {
		method: 'POST',
		headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
		body: JSON.stringify({ folder, username })
	});
	if (!response.ok) {
		throw new Error(await errorMessage(response, 'Could not connect the shared folder.'));
	}
	return (await response.json()) as SharedFolderConnection;
}

export async function disconnectSharedFolder(): Promise<void> {
	const response = await fetch('/api/sharing/disconnect', {
		method: 'POST',
		headers: { Accept: 'application/json' }
	});
	if (!response.ok) {
		throw new Error(await errorMessage(response, 'Could not disconnect the shared folder.'));
	}
}

export async function loadSharedInbox(): Promise<LibraryProjection> {
	const response = await fetch('/api/inbox', {
		headers: { Accept: 'application/json' },
		cache: 'no-store'
	});
	if (response.status === 401 || response.status === 404) {
		return {
			schemaVersion: 3,
			generatedAt: new Date().toISOString(),
			files: [],
			entries: []
		};
	}
	if (!response.ok) {
		throw new Error(await errorMessage(response, 'Could not synchronize the shared Inbox.'));
	}
	return parseLibraryProjection(await response.json());
}

export async function saveSharedInboxItem(referenceID: string): Promise<{
	saved: boolean;
	path: string;
	captureID: string;
}> {
	const response = await fetch(`/api/inbox/${encodeURIComponent(referenceID)}/save`, {
		method: 'POST',
		headers: { Accept: 'application/json' }
	});
	if (!response.ok) {
		throw new Error(await errorMessage(response, 'Could not save this Inbox item.'));
	}
	return (await response.json()) as {
		saved: boolean;
		path: string;
		captureID: string;
	};
}

export async function dismissSharedInboxItem(referenceID: string): Promise<void> {
	const response = await fetch(`/api/inbox/${encodeURIComponent(referenceID)}/dismiss`, {
		method: 'POST',
		headers: { Accept: 'application/json' }
	});
	if (!response.ok) {
		throw new Error(await errorMessage(response, 'Could not dismiss this Inbox item.'));
	}
}
