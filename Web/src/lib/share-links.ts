import type { LibraryVariant } from '$lib/library.js';

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
}

export interface PendingPublicShare {
	status: 'preparing' | 'failed';
	error?: string;
}

export type ContentReportCategory = 'copyright' | 'privacy' | 'child-safety' | 'other';

export interface ContentReport {
	category: ContentReportCategory;
	variant?: LibraryVariant;
	reporterName?: string;
	reporterEmail?: string;
	workDescription?: string;
	explanation: string;
	goodFaith: boolean;
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
	source?: ShareLinkSource
): Promise<ShareLinkStatus> {
	const response = await fetch('/api/share-links', {
		method: 'POST',
		headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
		body: JSON.stringify({ captureID, source })
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

export async function submitContentReport(
	token: string,
	report: ContentReport
): Promise<{ id: string; receivedAt: string }> {
	const response = await fetch(`/api/public/shares/${encodeURIComponent(token)}/reports`, {
		method: 'POST',
		headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
		body: JSON.stringify(report)
	});
	if (!response.ok) {
		throw new Error(await responseError(response, 'The report could not be submitted.'));
	}
	return (await response.json()) as { id: string; receivedAt: string };
}
