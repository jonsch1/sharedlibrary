import type { LibraryVariant } from '$lib/library.js';
import type { OpenRouterVoice } from '$lib/openrouter.js';

export interface ShareLinkStatus {
	shared: boolean;
	token?: string;
	url?: string;
	status?: 'preparing' | 'ready' | 'failed';
	revision?: number;
	error?: string;
	voice?: OpenRouterVoice;
	updatedAt?: string;
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

export async function publishShareLink(
	captureID: string,
	voice: OpenRouterVoice,
	model: string
): Promise<ShareLinkStatus> {
	const response = await fetch('/api/share-links', {
		method: 'POST',
		headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
		body: JSON.stringify({ captureID, voice, model })
	});
	if (response.status === 401) throw new Error('Sign in to create a share link.');
	if (!response.ok) {
		throw new Error(await responseError(response, 'Could not create the share link.'));
	}
	return (await response.json()) as ShareLinkStatus;
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
	return (await response.json()) as {
		saved: boolean;
		path: string;
		captureID: string;
	};
}
