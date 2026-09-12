import type { LibraryVariant } from '$lib/library.js';

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
