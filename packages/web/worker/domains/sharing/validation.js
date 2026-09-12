import {
	libraryVariants,
	readingDepths,
	sourceVariant
} from '../../../src/lib/reader/reading-depth.ts';

const maximumActiveShareLinks = 100;
const maximumContentReportsPerSharePerDay = 20;
const contentReportCategories = new Set(['copyright', 'privacy', 'child-safety', 'other']);
const shareVariants = readingDepths;
const shareInputVariants = libraryVariants;
const maximumShareDocumentBytes = 1_000_000;
const maximumSharePayloadBytes = 3_000_000;
const maximumShareTextBytesPerAccount = 100_000_000;

function validCaptureIdentifier(value) {
	return typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$/.test(value);
}

function wordCount(text) {
	return text.trim() ? text.trim().split(/\s+/u).length : 0;
}

function scheduleSharingOperation(context, task) {
	if (context?.waitUntil) context.waitUntil(task);
	else void task;
}

function validShareToken(value) {
	return typeof value === 'string' && /^[A-Za-z0-9_-]{32}$/.test(value);
}

function shareLinkURL(request, token) {
	const url = new URL('/', request.url);
	url.searchParams.set('shared', token);
	return url.toString();
}

function shareSourceString(value, maximumLength, required = false) {
	if (value === undefined && !required) return undefined;
	if (typeof value !== 'string' || value.length > maximumLength || (required && !value.trim())) {
		throw new Error('The selected document contains invalid metadata.');
	}
	return value;
}

function shareSourceStrings(value) {
	if (
		!Array.isArray(value) ||
		value.length > 100 ||
		value.some((item) => typeof item !== 'string' || item.length > 256)
	) {
		throw new Error('The selected document contains invalid metadata.');
	}
	return value;
}

function directShareSource(value, captureID) {
	if (value === undefined) return null;
	if (typeof value !== 'object' || value === null || Array.isArray(value)) {
		throw new Error('The selected document is invalid.');
	}
	if (
		typeof value.filename !== 'string' ||
		!/^[^/\\]{1,255}\.md$/i.test(value.filename) ||
		!Array.isArray(value.texts) ||
		value.texts.length < 1 ||
		value.texts.length > shareInputVariants.length
	) {
		throw new Error('The selected document is invalid.');
	}
	const title = shareSourceString(value.title, 500, true);
	const excerpt = shareSourceString(value.excerpt, 2_000) ?? '';
	const documents = [];
	const variants = new Set();
	let totalBytes = 0;
	for (const document of value.texts) {
		if (
			typeof document !== 'object' ||
			document === null ||
			!shareInputVariants.includes(document.variant) ||
			variants.has(document.variant) ||
			typeof document.markdown !== 'string'
		) {
			throw new Error('The selected document is invalid.');
		}
		const byteCount = new TextEncoder().encode(document.markdown).byteLength;
		if (byteCount > maximumShareDocumentBytes) {
			throw new Error('The selected document is too large to share.');
		}
		variants.add(document.variant);
		if (document.variant === sourceVariant) continue;
		totalBytes += byteCount;
		if (totalBytes > maximumSharePayloadBytes) {
			throw new Error('The selected document is too large to share.');
		}
		documents.push({
			variant: document.variant,
			markdown: document.markdown,
			wordCount: wordCount(document.markdown)
		});
	}
	if (!documents.length) throw new Error('The selected document has no summary to share.');
	return {
		entry: {
			captureID,
			title,
			excerpt,
			topicIDs: shareSourceStrings(value.topicIDs),
			topicNames: shareSourceStrings(value.topicNames),
			tags: shareSourceStrings(value.tags),
			sourceURL: shareSourceString(value.sourceURL, 2_048),
			createdAt: shareSourceString(value.createdAt, 64),
			updatedAt: shareSourceString(value.updatedAt, 64)
		},
		sourcePath: 'library/' + value.filename,
		documents
	};
}

function validateShareDocuments(documents) {
	let totalBytes = 0;
	for (const document of documents) {
		const byteCount = new TextEncoder().encode(document.markdown).byteLength;
		totalBytes += byteCount;
		if (byteCount > maximumShareDocumentBytes || totalBytes > maximumSharePayloadBytes) {
			throw new Error('The selected document is too large to share.');
		}
	}
	return totalBytes;
}

function contentReportString(value, maximumLength, required = false) {
	if (value === undefined || value === null) {
		if (required) throw new Error('Complete every required report field.');
		return undefined;
	}
	if (typeof value !== 'string') throw new Error('The report contains invalid text.');
	const result = value.trim();
	if ((required && !result) || result.length > maximumLength) {
		throw new Error('The report contains invalid text.');
	}
	return result || undefined;
}

export {
	contentReportCategories,
	contentReportString,
	directShareSource,
	maximumActiveShareLinks,
	maximumContentReportsPerSharePerDay,
	maximumShareTextBytesPerAccount,
	scheduleSharingOperation,
	shareInputVariants,
	shareLinkURL,
	shareSourceString,
	shareSourceStrings,
	shareVariants,
	sourceVariant,
	validCaptureIdentifier,
	validShareToken,
	validateShareDocuments,
	wordCount
};
