import type { LibraryVariant } from '$lib/library.js';
import {
	iCloudIdentity,
	importICloudShare,
	type ICloudShareImport
} from '$lib/icloud.js';
import type { OpenRouterVoice } from '$lib/openrouter.js';

export interface ShareLinkStatus {
	shared: boolean;
	token?: string;
	generation?: string;
	url?: string;
	captureID?: string;
	status?: 'preparing' | 'ready' | 'failed';
	revision?: number;
	error?: string;
	metadata?: {
		title?: string;
		excerpt?: string;
	};
	voice?: OpenRouterVoice;
	updatedAt?: string;
}

export interface ShareLinkSource {
	filename: string;
	title: string;
	excerpt: string;
	topicIDs: string[];
	topicNames: string[];
	tags: string[];
	sourceURL?: string;
	createdAt?: string;
	updatedAt?: string;
	texts: Array<{ variant: LibraryVariant; markdown: string }>;
}

export interface PublishedShareLinks {
	limit: number;
	links: ShareLinkStatus[];
}

export interface PublicShareText {
	variant: LibraryVariant;
	markdown: string;
	wordCount: number;
}

export interface PublicShareAudioSegment {
	variant: LibraryVariant;
	index: number;
	contentType: string;
	byteCount: number;
	voice: OpenRouterVoice;
	url: string;
}

export interface PublicShareDocument {
	status: 'ready';
	token: string;
	revision: number;
	captureID?: string;
	title: string;
	excerpt: string;
	topicIDs: string[];
	topicNames: string[];
	tags: string[];
	sourceURL?: string;
	createdAt?: string;
	updatedAt?: string;
	texts: PublicShareText[];
	audio: PublicShareAudioSegment[];
}

export interface PendingPublicShare {
	status: 'preparing' | 'failed';
	error?: string;
}

async function responseError(response: Response, fallback: string): Promise<string> {
	try {
		const value = (await response.json()) as { error?: string; message?: string };
		if (typeof value.error === 'string') return value.error;
		if (typeof value.message === 'string') return value.message;
	} catch {
		// The response was not JSON.
	}
	return fallback;
}

export async function loadShareLinkStatus(captureID: string): Promise<ShareLinkStatus> {
	const response = await fetch(`/api/share-links?captureID=${encodeURIComponent(captureID)}`, {
		headers: { Accept: 'application/json' },
		cache: 'no-store'
	});
	if (response.status === 401) throw new Error('Sign in to create a share link.');
	if (!response.ok) {
		throw new Error(await responseError(response, 'Could not load the share link.'));
	}
	return (await response.json()) as ShareLinkStatus;
}

export async function loadPublishedShareLinks(): Promise<PublishedShareLinks> {
	const response = await fetch('/api/share-links', {
		headers: { Accept: 'application/json' },
		cache: 'no-store'
	});
	if (response.status === 401) return { limit: 200, links: [] };
	if (!response.ok) {
		throw new Error(await responseError(response, 'Could not load your published links.'));
	}
	return (await response.json()) as PublishedShareLinks;
}

export async function publishShareLink(
	captureID: string,
	voice: OpenRouterVoice,
	model: string,
	source?: ShareLinkSource
): Promise<ShareLinkStatus> {
	const response = await fetch('/api/share-links', {
		method: 'POST',
		headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
		body: JSON.stringify({ captureID, voice, model, source })
	});
	if (response.status === 401) throw new Error('Sign in to create a share link.');
	if (!response.ok) {
		throw new Error(await responseError(response, 'Could not create the share link.'));
	}
	return (await response.json()) as ShareLinkStatus;
}

export async function publishShareAudio(
	share: Pick<ShareLinkStatus, 'token' | 'generation'>,
	variant: LibraryVariant,
	index: number,
	hash: string,
	voice: OpenRouterVoice,
	audio: Blob
): Promise<void> {
	if (!share.token || !share.generation) return;
	const response = await fetch(
		`/api/share-links/${encodeURIComponent(share.token)}/audio/${encodeURIComponent(share.generation)}/${variant}/${index}/${hash}`,
		{
			method: 'PUT',
			headers: {
				'Content-Type': audio.type || 'audio/mpeg',
				'X-Briefly-Voice': voice
			},
			body: audio
		}
	);
	if (!response.ok) {
		throw new Error(await responseError(response, 'Could not publish existing narration.'));
	}
}

export async function revokeShareLink(token: string): Promise<void> {
	const response = await fetch(`/api/share-links/${encodeURIComponent(token)}`, {
		method: 'DELETE',
		headers: { Accept: 'application/json' }
	});
	if (!response.ok) {
		throw new Error(await responseError(response, 'Could not revoke the share link.'));
	}
}

export async function loadPublicShare(
	token: string
): Promise<PublicShareDocument | PendingPublicShare> {
	const response = await fetch(`/api/public/shares/${encodeURIComponent(token)}`, {
		headers: { Accept: 'application/json' },
		cache: 'no-store'
	});
	if (response.status === 202 || response.status === 409) {
		return (await response.json()) as PendingPublicShare;
	}
	if (!response.ok) {
		throw new Error(await responseError(response, 'This share link is unavailable.'));
	}
	return (await response.json()) as PublicShareDocument;
}

export async function importPublicShare(token: string): Promise<{
	saved: boolean;
	path: string;
	captureID: string;
}> {
	const response = await fetch(`/api/public/shares/${encodeURIComponent(token)}/import`, {
		method: 'POST',
		headers: {
			Accept: 'application/json',
			Origin: window.location.origin
		}
	});
	if (response.status === 401) {
		const returnTo = `/?shared=${encodeURIComponent(token)}&import=1`;
		window.location.assign(
			`/signin-with-chatgpt?return_to=${encodeURIComponent(returnTo)}`
		);
		throw new Error('Opening sign in…');
	}
	if (!response.ok) {
		throw new Error(await responseError(response, 'Could not add this document to your library.'));
	}
	const result = (await response.json()) as {
		saved: boolean;
		path: string;
		captureID: string;
		provider?: 'icloud';
		source?: ICloudShareImport;
	};
	if (result.provider !== 'icloud' || !result.source) return result;
	if (!(await iCloudIdentity().catch(() => null))?.userRecordName) {
		const returnTo = new URL(window.location.href);
		returnTo.searchParams.set('import', '1');
		window.location.assign(
			`/icloud?return_to=${encodeURIComponent(`${returnTo.pathname}${returnTo.search}${returnTo.hash}`)}`
		);
		throw new Error('Opening iCloud…');
	}
	return importICloudShare(result.source);
}
