import {
	mirrorLibraryProjection,
	parseLibraryProjection,
	type LibraryFile,
	type LibraryMedia,
	type LibraryProjection
} from '$lib/library.js';

export type SyncProvider = 'google' | 'icloud';

export const emptyICloudLibraryMessage =
	'iCloud is connected, but no library has been uploaded yet. Open Briefly on the device with your library and sync there.';

export interface CloudLibraryMirror {
	index: LibraryProjection;
	files: Array<LibraryFile & { content: string }>;
	media: Array<LibraryMedia & { content: string }>;
}

interface CloudKitConfiguration {
	containerIdentifier: string;
	apiToken: string;
	environment: 'development' | 'production';
}

interface CloudKitRecord {
	recordName?: string;
	recordType?: string;
	recordChangeTag?: string;
	fields?: Record<string, { value?: unknown }>;
	serverErrorCode?: string;
	reason?: string;
}

interface CloudKitResponse {
	records?: CloudKitRecord[];
	errors?: Array<{ serverErrorCode?: string; reason?: string }>;
}

interface CloudKitDatabase {
	fetchRecordZones(zones: string | string[]): Promise<{ zones?: unknown[] }>;
	saveRecordZones(zones: string | string[]): Promise<unknown>;
	fetchRecords(
		records: string | string[],
		options?: { zoneID?: string }
	): Promise<CloudKitResponse>;
	saveRecords(
		records: CloudKitRecord | CloudKitRecord[],
		options?: { zoneID?: string }
	): Promise<CloudKitResponse>;
	deleteRecords(
		records: string | string[],
		options?: { zoneID?: string }
	): Promise<unknown>;
	performQuery(
		query: { recordType: string },
		options?: { zoneID?: string; resultsLimit?: number }
	): Promise<{ records?: CloudKitRecord[]; continuationMarker?: string; moreComing?: boolean }>;
}

interface CloudKitContainer {
	privateCloudDatabase: CloudKitDatabase;
	setUpAuth(): Promise<{ userRecordName?: string } | null>;
	whenUserSignsIn(): Promise<{ userRecordName?: string }>;
}

interface CloudKitGlobal {
	configure(config: unknown): void;
	getDefaultContainer(): CloudKitContainer;
}

declare global {
	interface Window {
		CloudKit?: CloudKitGlobal;
		brieflyICloud?: {
			status(): Promise<boolean>;
			fetchLibraryIndex(): Promise<LibraryProjection | null>;
			fetchLibraryFile(file: LibraryFile): Promise<string>;
			fetchLibraryMedia(media: LibraryMedia): Promise<string>;
			uploadLibrary(mirror: CloudLibraryMirror): Promise<{ changed: number; syncedAt: string }>;
		};
	}
}

const cloudKitScriptURL = 'https://cdn.apple-cloudkit.com/ck/2/cloudkit.js';
const zoneName = 'Briefly';
const indexRecordName = 'library-index';
let scriptPromise: Promise<void> | null = null;
let configured: Promise<CloudKitContainer> | null = null;
let database: CloudKitDatabase | null = null;

async function responseError(response: Response, fallback: string): Promise<Error> {
	try {
		const value = (await response.json()) as { error?: string };
		if (typeof value.error === 'string') return new Error(value.error);
	} catch {
		// The response was not JSON.
	}
	return new Error(fallback);
}

async function configuration(): Promise<CloudKitConfiguration> {
	const response = await fetch('/api/icloud/config', {
		headers: { Accept: 'application/json' },
		cache: 'no-store'
	});
	if (!response.ok) throw await responseError(response, 'iCloud sync is not configured.');
	return response.json() as Promise<CloudKitConfiguration>;
}

function loadCloudKit(): Promise<void> {
	if (window.CloudKit) return Promise.resolve();
	if (scriptPromise) return scriptPromise;
	scriptPromise = new Promise((resolve, reject) => {
		const script = document.createElement('script');
		script.src = cloudKitScriptURL;
		script.async = true;
		script.onload = () => resolve();
		script.onerror = () => reject(new Error('CloudKit could not be loaded from Apple.'));
		document.head.append(script);
	});
	return scriptPromise;
}

export async function cloudKitContainer(): Promise<CloudKitContainer> {
	if (configured) return configured;
	configured = (async () => {
		const config = await configuration();
		await loadCloudKit();
		if (!window.CloudKit) throw new Error('CloudKit is unavailable.');
		window.CloudKit.configure({
			containers: [
				{
					containerIdentifier: config.containerIdentifier,
					environment: config.environment,
					apiTokenAuth: {
						apiToken: config.apiToken,
						persist: true,
						signInButton: { id: 'apple-sign-in-button', theme: 'black' },
						signOutButton: { id: 'apple-sign-out-button', theme: 'black' }
					}
				}
			]
		});
		return window.CloudKit.getDefaultContainer();
	})();
	return configured;
}

export async function iCloudIdentity(): Promise<{ userRecordName?: string } | null> {
	return (await cloudKitContainer()).setUpAuth();
}

export async function waitForICloudSignIn(): Promise<{ userRecordName?: string }> {
	return (await cloudKitContainer()).whenUserSignsIn();
}

export async function selectICloudSync(): Promise<void> {
	const response = await fetch('/api/sync/provider', {
		method: 'POST',
		headers: {
			Accept: 'application/json',
			'Content-Type': 'application/json'
		},
		body: JSON.stringify({ provider: 'icloud' })
	});
	if (!response.ok) throw await responseError(response, 'iCloud could not be selected.');
}

export async function disconnectICloud(): Promise<void> {
	const response = await fetch('/api/icloud/disconnect', {
		method: 'POST',
		headers: { Accept: 'application/json' }
	});
	if (!response.ok) throw await responseError(response, 'iCloud could not be disconnected.');
}

async function privateDatabase(): Promise<CloudKitDatabase> {
	if (database) return database;
	const container = await cloudKitContainer();
	const identity = await container.setUpAuth();
	if (!identity?.userRecordName) throw new Error('Connect iCloud to synchronize this library.');
	database = container.privateCloudDatabase;
	return database;
}

function cloudErrorCode(error: unknown): string {
	if (typeof error !== 'object' || error === null) return '';
	const value = error as Record<string, unknown>;
	return String(value.serverErrorCode ?? value.ckErrorCode ?? value.name ?? '');
}

async function ensureZone(): Promise<CloudKitDatabase> {
	const result = await privateDatabase();
	try {
		const response = await result.fetchRecordZones(zoneName);
		if (response.zones?.length) return result;
	} catch {
		// The zone is created below.
	}
	try {
		await result.saveRecordZones(zoneName);
	} catch (error) {
		if (!/already|exists/i.test(`${cloudErrorCode(error)} ${String(error)}`)) throw error;
	}
	return result;
}

function recordField<T>(record: CloudKitRecord, name: string): T | undefined {
	return record.fields?.[name]?.value as T | undefined;
}

async function fetchRecord(name: string): Promise<CloudKitRecord | null> {
	const result = await ensureZone();
	const response = await result.fetchRecords(name, { zoneID: zoneName });
	const record = response.records?.[0];
	const error = response.errors?.[0];
	if (
		!record &&
		(error?.serverErrorCode === 'UNKNOWN_ITEM' || error?.serverErrorCode === 'NOT_FOUND')
	) {
		return null;
	}
	if (error) throw new Error(error.reason || error.serverErrorCode || 'CloudKit request failed.');
	if (!record || record.serverErrorCode === 'UNKNOWN_ITEM') return null;
	if (record.serverErrorCode) throw new Error(record.reason || record.serverErrorCode);
	return record;
}

function assetURL(record: CloudKitRecord, field: string, filename: string): string {
	const asset = recordField<{ downloadURL?: string }>(record, field);
	if (!asset?.downloadURL) throw new Error('CloudKit returned a record without its asset.');
	return asset.downloadURL.replace('${f}', encodeURIComponent(filename));
}

async function downloadAsset(record: CloudKitRecord, field: string, filename: string): Promise<Blob> {
	const response = await fetch(assetURL(record, field, filename), { cache: 'no-store' });
	if (!response.ok) throw new Error(`CloudKit could not download ${filename}.`);
	return response.blob();
}

async function sha256(value: string | ArrayBuffer): Promise<string> {
	const bytes = typeof value === 'string' ? new TextEncoder().encode(value) : value;
	const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
	return [...digest].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

async function fileRecordName(path: string): Promise<string> {
	return `file-${await sha256(path)}`;
}

function mediaRecordName(media: Pick<LibraryMedia, 'kind' | 'contentHash'>): string {
	return `media-${media.kind}-${media.contentHash}`;
}

async function saveRecord(
	name: string,
	type: 'BrieflyLibraryIndex' | 'BrieflyLibraryFile' | 'BrieflyLibraryMedia',
	fields: CloudKitRecord['fields'],
	expectedChangeTag?: string | null
): Promise<void> {
	const result = await ensureZone();
	const changeTag =
		expectedChangeTag === undefined
			? (await fetchRecord(name))?.recordChangeTag
			: expectedChangeTag;
	const record: CloudKitRecord = {
		recordName: name,
		recordType: type,
		fields
	};
	if (changeTag) record.recordChangeTag = changeTag;
	const response = await result.saveRecords(record, { zoneID: zoneName });
	const error = response.errors?.[0];
	if (error) throw new Error(error.reason || error.serverErrorCode || 'CloudKit save failed.');
	const saved = response.records?.[0];
	if (saved?.serverErrorCode) throw new Error(saved.reason || saved.serverErrorCode);
}

async function deleteRecords(names: string[]): Promise<void> {
	if (!names.length) return;
	const result = await ensureZone();
	for (let index = 0; index < names.length; index += 100) {
		await result.deleteRecords(names.slice(index, index + 100), { zoneID: zoneName });
	}
}

async function fetchICloudLibraryState(): Promise<{
	projection: LibraryProjection | null;
	changeTag: string | null;
}> {
	const record = await fetchRecord(indexRecordName);
	if (!record) return { projection: null, changeTag: null };
	const blob = await downloadAsset(record, 'payload', 'library-index.json');
	return {
		projection: parseLibraryProjection(JSON.parse(await blob.text())),
		changeTag: record.recordChangeTag ?? null
	};
}

export async function fetchICloudLibraryIndex(): Promise<LibraryProjection | null> {
	return (await fetchICloudLibraryState()).projection;
}

export async function fetchICloudLibraryFile(
	file: Pick<LibraryFile, 'path' | 'contentHash'>
): Promise<string> {
	const record = await fetchRecord(await fileRecordName(file.path));
	if (
		!record ||
		recordField<string>(record, 'path') !== file.path ||
		recordField<string>(record, 'contentHash') !== file.contentHash
	) {
		throw new Error(`CloudKit does not contain the expected copy of ${file.path}.`);
	}
	const blob = await downloadAsset(record, 'content', file.path.split('/').at(-1) || 'file.md');
	const bytes = await blob.arrayBuffer();
	if ((await sha256(bytes)) !== file.contentHash) {
		throw new Error(`CloudKit returned an invalid copy of ${file.path}.`);
	}
	return new TextDecoder().decode(bytes);
}

export async function fetchICloudLibraryMediaURL(media: LibraryMedia): Promise<string> {
	const record = await fetchRecord(mediaRecordName(media));
	if (
		!record ||
		recordField<string>(record, 'kind') !== media.kind ||
		recordField<string>(record, 'contentHash') !== media.contentHash
	) {
		throw new Error(`CloudKit does not contain the expected copy of ${media.path}.`);
	}
	return assetURL(record, 'content', media.path.split('/').at(-1) || media.contentHash);
}

async function fetchICloudLibraryMedia(media: LibraryMedia): Promise<string> {
	const record = await fetchRecord(mediaRecordName(media));
	if (!record || recordField<string>(record, 'contentHash') !== media.contentHash) {
		throw new Error(`CloudKit does not contain the expected copy of ${media.path}.`);
	}
	const blob = await downloadAsset(
		record,
		'content',
		media.path.split('/').at(-1) || media.contentHash
	);
	const bytes = new Uint8Array(await blob.arrayBuffer());
	if (bytes.byteLength !== media.byteCount || (await sha256(bytes.buffer)) !== media.contentHash) {
		throw new Error(`CloudKit returned an invalid copy of ${media.path}.`);
	}
	return bytesToBase64(bytes);
}

async function mapWithConcurrency<T>(
	values: T[],
	operation: (value: T) => Promise<void>
): Promise<void> {
	let next = 0;
	await Promise.all(
		Array.from({ length: Math.min(4, values.length) }, async () => {
			while (next < values.length) {
				const value = values[next];
				next += 1;
				await operation(value);
			}
		})
	);
}

async function uploadICloudLibraryMedia(
	media: LibraryMedia & { content: string }
): Promise<boolean> {
	const name = mediaRecordName(media);
	const existing = await fetchRecord(name);
	if (
		recordField<string>(existing ?? {}, 'contentHash') === media.contentHash &&
		recordField<number>(existing ?? {}, 'byteCount') === media.byteCount
	) {
		return false;
	}
	const bytes = base64ToBytes(media.content);
	const content = bytes.slice().buffer;
	if (bytes.byteLength !== media.byteCount || (await sha256(content)) !== media.contentHash) {
		throw new Error(`The synchronized copy of ${media.path} is invalid.`);
	}
	await saveRecord(
		name,
		'BrieflyLibraryMedia',
		{
			kind: { value: media.kind },
			path: { value: media.path },
			contentHash: { value: media.contentHash },
			byteCount: { value: media.byteCount },
			contentType: { value: media.contentType },
			content: { value: new Blob([content], { type: media.contentType }) }
		},
		existing?.recordChangeTag
	);
	return true;
}

export async function uploadICloudLibrary(
	mirror: CloudLibraryMirror
): Promise<{ changed: number; syncedAt: string }> {
	const cleansMedia = Array.isArray(mirror.media);
	let mediaChanged = 0;
	await mapWithConcurrency(mirror.media ?? [], async (media) => {
		if (await uploadICloudLibraryMedia(media)) mediaChanged += 1;
	});
	const state = await fetchICloudLibraryState();
	const remote = state.projection;
	const remoteHashes = new Map(remote?.files.map((file) => [file.path, file.contentHash]) ?? []);
	const changed = mirror.files.filter(
		(file) => remoteHashes.get(file.path) !== file.contentHash
	);
	await mapWithConcurrency(changed, async (file) => {
		await saveRecord(await fileRecordName(file.path), 'BrieflyLibraryFile', {
			path: { value: file.path },
			contentHash: { value: file.contentHash },
			byteCount: { value: file.byteCount },
			content: { value: new Blob([file.content], { type: 'text/markdown;charset=utf-8' }) }
		});
	});
	const activePaths = new Set(mirror.files.map((file) => file.path));
	const stale = (remote?.files ?? []).filter((file) => !activePaths.has(file.path));
	const activeMedia = new Set((mirror.media ?? []).map(mediaRecordName));
	const staleMedia = new Set(
		cleansMedia
			? (remote?.entries ?? [])
					.flatMap((entry) => [entry.audio, entry.favicon])
					.filter((media): media is LibraryMedia => Boolean(media))
					.map(mediaRecordName)
					.filter((name) => !activeMedia.has(name))
			: []
	);
	await saveRecord(indexRecordName, 'BrieflyLibraryIndex', {
		schemaVersion: { value: mirror.index.schemaVersion },
		generatedAt: { value: Date.now() },
		payload: {
			value: new Blob([JSON.stringify(mirror.index)], { type: 'application/json' })
		}
	}, state.changeTag);
	await deleteRecords([
		...(await Promise.all(stale.map((file) => fileRecordName(file.path)))),
		...staleMedia
	]);
	return {
		changed: mediaChanged + changed.length + stale.length + staleMedia.size,
		syncedAt: new Date().toISOString()
	};
}

export async function syncICloudLibrary(
	onProjectionAvailable?: (projection: LibraryProjection) => void,
	onProgress?: (completed: number, total: number) => void
): Promise<LibraryProjection | null> {
	const projection = await fetchICloudLibraryIndex();
	if (!projection) return null;
	onProjectionAvailable?.(projection);
	await mirrorLibraryProjection(
		projection,
		(progress) => onProgress?.(progress.completed, progress.total),
		fetchICloudLibraryFile
	);
	return projection;
}

export function exposeICloudBridge(): void {
	window.brieflyICloud = {
		status: async () => Boolean((await iCloudIdentity())?.userRecordName),
		fetchLibraryIndex: fetchICloudLibraryIndex,
		fetchLibraryFile: fetchICloudLibraryFile,
		fetchLibraryMedia: fetchICloudLibraryMedia,
		uploadLibrary: uploadICloudLibrary
	};
}

function base64ToBytes(value: string): Uint8Array {
	const binary = atob(value);
	return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function bytesToBase64(bytes: Uint8Array): string {
	let binary = '';
	for (let index = 0; index < bytes.length; index += 32_768) {
		binary += String.fromCharCode(...bytes.subarray(index, index + 32_768));
	}
	return btoa(binary);
}
