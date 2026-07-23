export const librarySchemaVersion = 2;

export const libraryVariants = [
	'brief',
	'concise',
	'detailed',
	'comprehensive',
	'source'
] as const;

export type LibraryVariant = (typeof libraryVariants)[number];
export type LibraryOrigin = 'personal' | 'shared';

export interface LibraryText {
	variant: LibraryVariant;
	path?: string;
	contentHash?: string;
	wordCount?: number;
	text?: string;
}

export interface LibraryEntry {
	id: string;
	captureID?: string;
	title: string;
	excerpt: string;
	topicIDs: string[];
	topicNames: string[];
	tags: string[];
	sourceURL?: string;
	createdAt?: string;
	updatedAt?: string;
	reviewedAt?: string;
	origin: LibraryOrigin;
	sharedByDisplayName?: string;
	texts: LibraryText[];
}

export interface LibraryProjection {
	schemaVersion: number;
	generatedAt: string;
	entries: LibraryEntry[];
}

const databaseName = 'shared-library-web';
const snapshotStoreName = 'snapshots';
const textStoreName = 'texts';
const activeSnapshotKey = 'active';

function isObject(value: unknown): value is Record<string, unknown> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isStringArray(value: unknown): value is string[] {
	return Array.isArray(value) && value.every((item) => typeof item === 'string');
}

function isLibraryText(value: unknown): value is LibraryText {
	return (
		isObject(value) &&
		typeof value.variant === 'string' &&
		libraryVariants.includes(value.variant as LibraryVariant) &&
		(typeof value.text === 'string' ||
			(typeof value.path === 'string' &&
				typeof value.contentHash === 'string' &&
				typeof value.wordCount === 'number'))
	);
}

function isLibraryEntry(value: unknown): value is LibraryEntry {
	return (
		isObject(value) &&
		typeof value.id === 'string' &&
		typeof value.title === 'string' &&
		typeof value.excerpt === 'string' &&
		isStringArray(value.topicIDs) &&
		isStringArray(value.topicNames) &&
		isStringArray(value.tags) &&
		(value.origin === 'personal' || value.origin === 'shared') &&
		Array.isArray(value.texts) &&
		value.texts.every(isLibraryText)
	);
}

export function parseLibraryProjection(value: unknown): LibraryProjection {
	if (
		!isObject(value) ||
		value.schemaVersion !== librarySchemaVersion ||
		typeof value.generatedAt !== 'string' ||
		Number.isNaN(Date.parse(value.generatedAt)) ||
		!Array.isArray(value.entries) ||
		!value.entries.every(isLibraryEntry)
	) {
		throw new Error(
			'This is not a compatible Shared Library Drive index. Open the Mac app and let it synchronize again.'
		);
	}
	return value as unknown as LibraryProjection;
}

function openDatabase(): Promise<IDBDatabase> {
	return new Promise((resolve, reject) => {
		const request = indexedDB.open(databaseName, 2);
		request.onupgradeneeded = () => {
			if (!request.result.objectStoreNames.contains(snapshotStoreName)) {
				request.result.createObjectStore(snapshotStoreName);
			}
			if (!request.result.objectStoreNames.contains(textStoreName)) {
				request.result.createObjectStore(textStoreName);
			}
		};
		request.onsuccess = () => resolve(request.result);
		request.onerror = () => reject(request.error ?? new Error('Could not open offline storage.'));
	});
}

export async function saveLibraryProjection(projection: LibraryProjection): Promise<void> {
	const database = await openDatabase();
	try {
		await new Promise<void>((resolve, reject) => {
			const transaction = database.transaction(snapshotStoreName, 'readwrite');
			transaction.objectStore(snapshotStoreName).put(projection, activeSnapshotKey);
			transaction.oncomplete = () => resolve();
			transaction.onerror = () =>
				reject(transaction.error ?? new Error('Could not save the offline library.'));
			transaction.onabort = () =>
				reject(transaction.error ?? new Error('Saving the offline library was interrupted.'));
		});
	} finally {
		database.close();
	}
}

export async function loadLibraryProjection(): Promise<LibraryProjection | null> {
	const database = await openDatabase();
	try {
		return await new Promise<LibraryProjection | null>((resolve, reject) => {
			const request = database
				.transaction(snapshotStoreName, 'readonly')
				.objectStore(snapshotStoreName)
				.get(activeSnapshotKey);
			request.onsuccess = () => {
				if (request.result === undefined) {
					resolve(null);
					return;
				}
				try {
					resolve(parseLibraryProjection(request.result));
				} catch (error) {
					reject(error);
				}
			};
			request.onerror = () =>
				reject(request.error ?? new Error('Could not read the offline library.'));
		});
	} finally {
		database.close();
	}
}

export function textFor(
	entry: LibraryEntry,
	variant: LibraryVariant
): LibraryText | undefined {
	return entry.texts.find((text) => text.variant === variant);
}

function textCacheKey(reference: LibraryText): string | null {
	if (!reference.path || !reference.contentHash) return null;
	return `${reference.contentHash}:${reference.path}`;
}

async function cachedLibraryText(reference: LibraryText): Promise<string | null> {
	const key = textCacheKey(reference);
	if (!key) return reference.text ?? null;
	const database = await openDatabase();
	try {
		return await new Promise<string | null>((resolve, reject) => {
			const request = database
				.transaction(textStoreName, 'readonly')
				.objectStore(textStoreName)
				.get(key);
			request.onsuccess = () =>
				resolve(typeof request.result === 'string' ? request.result : null);
			request.onerror = () =>
				reject(request.error ?? new Error('Could not read the offline document.'));
		});
	} finally {
		database.close();
	}
}

async function cacheLibraryText(reference: LibraryText, text: string): Promise<void> {
	const key = textCacheKey(reference);
	if (!key) return;
	const database = await openDatabase();
	try {
		await new Promise<void>((resolve, reject) => {
			const transaction = database.transaction(textStoreName, 'readwrite');
			transaction.objectStore(textStoreName).put(text, key);
			transaction.oncomplete = () => resolve();
			transaction.onerror = () =>
				reject(transaction.error ?? new Error('Could not cache the document.'));
		});
	} finally {
		database.close();
	}
}

export async function loadLibraryText(reference: LibraryText): Promise<string> {
	if (typeof reference.text === 'string') return reference.text;
	const cached = await cachedLibraryText(reference);
	if (cached !== null) return cached;
	if (!reference.path || !reference.contentHash) return '';
	const parameters = new URLSearchParams({
		path: reference.path,
		hash: reference.contentHash
	});
	const response = await fetch(`/api/library/file?${parameters.toString()}`, {
		headers: { Accept: 'text/markdown, text/plain' },
		cache: 'no-store'
	});
	if (!response.ok) {
		throw new Error(
			response.status === 404
				? 'This document is not available in Google Drive yet.'
				: 'The document could not be downloaded from Google Drive.'
		);
	}
	let text = await response.text();
	if (reference.variant === 'source') {
		text = text.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n?/, '').trim();
	}
	await cacheLibraryText(reference, text);
	return text;
}

export function preferredVariant(entry: LibraryEntry): LibraryVariant {
	for (const variant of ['concise', 'brief', 'detailed', 'comprehensive', 'source'] as const) {
		if (textFor(entry, variant)) return variant;
	}
	return 'source';
}

export function readingMinutes(text: string, rate = 1): number {
	const words = text.trim().split(/\s+/).filter(Boolean).length;
	return Math.max(1, Math.ceil(words / (180 * rate)));
}

export const demoProjection: LibraryProjection = {
	schemaVersion: librarySchemaVersion,
	generatedAt: new Date().toISOString(),
	entries: [
		{
			id: 'demo:network-inference',
			captureID: 'network-inference',
			title: 'A practical guide to biological network inference',
			excerpt:
				'How prior knowledge, perturbation data, and careful validation work together when reconstructing signaling networks.',
			topicIDs: ['systems-biology', 'methods'],
			topicNames: ['Systems Biology', 'Methods'],
			tags: ['networks', 'inference'],
			sourceURL: 'https://example.com/network-inference',
			createdAt: '2026-07-18T09:30:00Z',
			origin: 'personal',
			texts: [
				{
					variant: 'brief',
					text:
						'Network inference works best when experimental perturbations, prior biological knowledge, and explicit validation are designed together.'
				},
				{
					variant: 'concise',
					text:
						'## Core idea\n\nBiological network inference is not a single algorithmic step. It combines **well-designed perturbations**, a transparent prior network, and validation against held-out observations.\n\n- Use perturbations that distinguish competing causal explanations.\n- Keep prior knowledge inspectable and versioned.\n- Separate model selection from final validation.\n- Report uncertainty instead of presenting one graph as definitive.\n\nThe most useful inferred network is often the one that supports the next experiment, not the visually densest one.'
				},
				{
					variant: 'detailed',
					text:
						'## Designing the evidence\n\nPerturbations should be selected for identifiability. Measurements that merely repeat the same biological condition add volume without necessarily separating causal hypotheses.\n\n## Working with prior knowledge\n\nTreat the prior network as evidence with provenance, not as ground truth. Track sources, species, context, and confidence so that assumptions remain visible.\n\n## Validation\n\nReserve observations or experiments before fitting. Compare predictive performance, stability under resampling, and whether the model proposes useful follow-up experiments.'
				},
				{
					variant: 'source',
					text:
						'This sample document illustrates the format exported by Shared Library. Your real snapshot includes the original source text and every available summary level.'
				}
			]
		},
		{
			id: 'demo:data-pipelines',
			captureID: 'data-pipelines',
			title: 'Designing reliable scientific data pipelines',
			excerpt:
				'A compact checklist for reproducible transformations, observable failures, and outputs that can be rebuilt.',
			topicIDs: ['engineering', 'research-practice'],
			topicNames: ['Engineering', 'Research Practice'],
			tags: ['pipelines', 'reproducibility'],
			createdAt: '2026-07-14T14:00:00Z',
			origin: 'personal',
			texts: [
				{
					variant: 'concise',
					text:
						'## Reliable pipeline principles\n\n1. Make every transformation explicit and deterministic.\n2. Record inputs, versions, parameters, and checksums.\n3. Fail loudly at the boundary where invalid data first appears.\n4. Keep intermediate outputs disposable and rebuildable.\n5. Test scientific invariants in addition to software behavior.'
				},
				{
					variant: 'source',
					text:
						'Reliable research pipelines make provenance visible and turn recovery from partial failure into a normal operation.'
				}
			]
		},
		{
			id: 'demo:cell-communication',
			captureID: 'cell-communication',
			title: 'Cell–cell communication workflows',
			excerpt:
				'An annotated comparison of ligand–receptor analysis choices and the assumptions hidden inside common scoring strategies.',
			topicIDs: ['single-cell', 'methods'],
			topicNames: ['Single-cell', 'Methods'],
			tags: ['communication', 'ligand-receptor'],
			createdAt: '2026-07-10T11:45:00Z',
			origin: 'shared',
			sharedByDisplayName: 'Alex Morgan',
			texts: [
				{
					variant: 'brief',
					text:
						'Ligand–receptor scores are hypotheses about communication, not direct measurements of signaling events.'
				},
				{
					variant: 'concise',
					text:
						'## Interpreting communication scores\n\nMost workflows combine expression thresholds, a ligand–receptor resource, and an aggregation rule. Results change substantially with each choice.\n\nUse several complementary methods, keep the resource version visible, and validate important predictions with spatial context or perturbation data.'
				},
				{
					variant: 'source',
					text:
						'This item demonstrates how a document shared with you appears beside personal library content.'
				}
			]
		}
	]
};
