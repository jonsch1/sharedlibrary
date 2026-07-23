import { parseLibraryProjection, type LibraryProjection } from '$lib/library.js';

export interface SharedFolderConnection {
	connected: boolean;
	folderID?: string;
	folderName?: string;
	userID?: string;
	username?: string;
	connectedAt?: string;
}

export interface SharedPerson {
	userID: string;
	username: string;
}

export interface SharedItemStatus {
	shared: boolean;
	referenceID?: string;
	recipientIDs: string[];
	people: SharedPerson[];
	operationStatus?: 'queued' | 'syncing' | 'failed';
	operationError?: string;
}

export interface SharingOperationStatus {
	status: 'queued' | 'syncing' | 'failed' | 'complete';
	error?: string;
}

const sharedPeopleCacheKey = 'shared-library-shared-people-v1';
const sharedItemCacheKey = 'shared-library-shared-items-v1';

function validCachedPerson(value: unknown): value is SharedPerson {
	if (!value || typeof value !== 'object') return false;
	const person = value as Record<string, unknown>;
	return (
		typeof person.userID === 'string' &&
		person.userID.length > 0 &&
		typeof person.username === 'string' &&
		person.username.length > 0
	);
}

export function loadCachedSharedPeople(): SharedPerson[] {
	if (typeof localStorage === 'undefined') return [];
	try {
		const value = JSON.parse(localStorage.getItem(sharedPeopleCacheKey) ?? '[]') as unknown;
		return Array.isArray(value) ? value.filter(validCachedPerson) : [];
	} catch {
		return [];
	}
}

function cacheSharedPeople(people: SharedPerson[]): void {
	if (typeof localStorage === 'undefined' || people.length === 0) return;
	localStorage.setItem(sharedPeopleCacheKey, JSON.stringify(people));
}

function cacheSharedItemStatus(captureID: string, status: SharedItemStatus): void {
	if (typeof localStorage === 'undefined') return;
	try {
		const parsed = JSON.parse(localStorage.getItem(sharedItemCacheKey) ?? '{}') as unknown;
		const existing =
			parsed && typeof parsed === 'object' && !Array.isArray(parsed)
				? (parsed as Record<string, SharedItemStatus>)
				: {};
		existing[captureID] = {
			...status,
			people: status.people.length > 0 ? status.people : loadCachedSharedPeople()
		};
		localStorage.setItem(sharedItemCacheKey, JSON.stringify(existing));
	} catch {
		// A malformed cache is replaced on the next successful refresh.
		localStorage.removeItem(sharedItemCacheKey);
	}
}

export function loadCachedSharedItemStatus(captureID: string): SharedItemStatus | null {
	if (typeof localStorage === 'undefined') return null;
	try {
		const parsed = JSON.parse(localStorage.getItem(sharedItemCacheKey) ?? '{}') as unknown;
		if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return null;
		const existing = parsed as Record<string, SharedItemStatus>;
		const status = existing[captureID];
		if (!status || !Array.isArray(status.recipientIDs)) return null;
		return {
			...status,
			people: Array.isArray(status.people) ? status.people.filter(validCachedPerson) : []
		};
	} catch {
		return null;
	}
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

async function fetchWithTimeout(
	input: RequestInfo | URL,
	init: RequestInit,
	timeoutMilliseconds = 15_000
): Promise<Response> {
	const controller = new AbortController();
	const timeout = setTimeout(() => controller.abort(), timeoutMilliseconds);
	try {
		return await fetch(input, { ...init, signal: controller.signal });
	} catch (error) {
		if (error instanceof DOMException && error.name === 'AbortError') {
			throw new Error('Google Drive took too long to respond. Please try again.');
		}
		throw error;
	} finally {
		clearTimeout(timeout);
	}
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

export async function loadSharedItemStatus(captureID: string): Promise<SharedItemStatus> {
	const response = await fetchWithTimeout(
		`/api/sharing/item?captureID=${encodeURIComponent(captureID)}`,
		{
			headers: { Accept: 'application/json' },
			cache: 'no-store'
		},
		12_000
	);
	if (!response.ok) {
		throw new Error(await errorMessage(response, 'Could not load sharing details.'));
	}
	const status = (await response.json()) as SharedItemStatus;
	cacheSharedPeople(status.people);
	cacheSharedItemStatus(captureID, status);
	return status;
}

export async function updateSharedItem(
	captureID: string,
	recipientIDs: string[]
): Promise<SharedItemStatus> {
	const response = await fetchWithTimeout(
		'/api/sharing/item',
		{
			method: 'POST',
			headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
			body: JSON.stringify({ captureID, recipientIDs })
		},
		10_000
	);
	if (!response.ok) {
		throw new Error(await errorMessage(response, 'Could not update sharing.'));
	}
	const status = (await response.json()) as SharedItemStatus;
	cacheSharedItemStatus(captureID, status);
	return status;
}

export async function loadSharingOperationStatus(
	captureID: string
): Promise<SharingOperationStatus> {
	const response = await fetchWithTimeout(
		`/api/sharing/operation?captureID=${encodeURIComponent(captureID)}`,
		{
			headers: { Accept: 'application/json' },
			cache: 'no-store'
		},
		8_000
	);
	if (!response.ok) {
		throw new Error(await errorMessage(response, 'Could not check the Drive update.'));
	}
	return (await response.json()) as SharingOperationStatus;
}

export async function loadSharedInbox(): Promise<LibraryProjection> {
	const response = await fetchWithTimeout('/api/inbox', {
		headers: { Accept: 'application/json' },
		cache: 'no-store'
	}, 20_000);
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
