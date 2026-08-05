import {
	databaseChanges,
	emailAddressPattern,
	json,
	randomBase64URL,
	requireSameOrigin
} from './http-security.js';
import { authenticatedEmail } from './auth-accounts.js';

const maximumActiveShareLinks = 100;
const maximumContentReportsPerSharePerDay = 20;
const contentReportCategories = new Set(['copyright', 'privacy', 'child-safety', 'other']);
const shareVariants = ['concise', 'detailed'];
const shareInputVariants = [...shareVariants, 'source'];
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
		if (document.variant === 'source') continue;
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

async function ownerShareTextBytes(env, email, excludedToken) {
	const row = await env.DB.prepare(
		'SELECT COALESCE(SUM(length(CAST(text.markdown AS BLOB))), 0) AS byte_count\n' +
			'FROM share_texts text\n' +
			'JOIN share_links link ON link.token = text.share_token\n' +
			'WHERE link.owner_email = ? AND text.share_token <> ?'
	)
		.bind(email, excludedToken)
		.first();
	return Number(row?.byte_count ?? 0);
}

async function shareLinkForOwner(env, email, captureID) {
	return env.DB.prepare(
		'SELECT token, owner_email, capture_id, generation, revision, status,\n' +
			'       metadata_json, source_filename, error_message, created_at, updated_at\n' +
			'FROM share_links\n' +
			'WHERE owner_email = ? AND capture_id = ?'
	)
		.bind(email, captureID)
		.first();
}

async function shareLinkByToken(env, token) {
	return env.DB.prepare(
		'SELECT token, owner_email, capture_id, generation, revision, status,\n' +
			'       metadata_json, source_filename, error_message, created_at, updated_at\n' +
			'FROM share_links\n' +
			'WHERE token = ?'
	)
		.bind(token)
		.first();
}

async function shareLinksForOwner(env, email) {
	return env.DB.prepare(
		'SELECT token, owner_email, capture_id, generation, revision, status,\n' +
			'       metadata_json, source_filename, error_message, created_at, updated_at\n' +
			'FROM share_links\n' +
			'WHERE owner_email = ?\n' +
			'ORDER BY updated_at DESC\n' +
			'LIMIT ?'
	)
		.bind(email, maximumActiveShareLinks)
		.all();
}

function shareLinkResponse(request, record) {
	if (!record) return { shared: false };
	let metadata;
	try {
		metadata = record.metadata_json ? JSON.parse(record.metadata_json) : undefined;
	} catch {
		metadata = undefined;
	}
	return {
		shared: true,
		token: record.token,
		generation: record.generation,
		url: shareLinkURL(request, record.token),
		status: record.status,
		revision: Number(record.revision ?? 1),
		error: record.error_message ?? undefined,
		metadata,
		updatedAt: record.updated_at
	};
}

async function removeShareGeneration(env, token, generation) {
	await env.DB.prepare('DELETE FROM share_texts WHERE share_token = ? AND generation = ?')
		.bind(token, generation)
		.run();
}

async function removeOldShareGenerations(env, token, currentGeneration) {
	await env.DB.prepare('DELETE FROM share_texts WHERE share_token = ? AND generation <> ?')
		.bind(token, currentGeneration)
		.run();
}

async function prepareShareLink(env, email, token, captureID, generation, source) {
	try {
		if (!source?.documents?.length) throw new Error('No summary is available to share.');
		const textBytes = validateShareDocuments(source.documents);
		if (
			(await ownerShareTextBytes(env, email, token)) + textBytes >
			maximumShareTextBytesPerAccount
		) {
			throw new Error('This account has reached its public sharing storage limit.');
		}
		for (const document of source.documents) {
			await env.DB.prepare(
				'INSERT OR REPLACE INTO share_texts (\n' +
					'	share_token, generation, variant, markdown, word_count\n' +
					') VALUES (?, ?, ?, ?, ?)'
			)
				.bind(token, generation, document.variant, document.markdown, document.wordCount)
				.run();
		}
		const metadata = {
			captureID: source.entry.captureID ?? captureID,
			title: source.entry.title,
			excerpt: source.entry.excerpt,
			topicIDs: source.entry.topicIDs ?? [],
			topicNames: source.entry.topicNames ?? [],
			tags: source.entry.tags ?? [],
			sourceURL: source.entry.sourceURL,
			createdAt: source.entry.createdAt,
			updatedAt: source.entry.updatedAt
		};
		const completed = await env.DB.prepare(
			'UPDATE share_links\n' +
				'SET status = \'ready\', metadata_json = ?, source_filename = ?,\n' +
				'    error_message = NULL, updated_at = ?\n' +
				'WHERE token = ? AND generation = ?'
		)
			.bind(
				JSON.stringify(metadata),
				source.sourcePath.split('/').at(-1),
				new Date().toISOString(),
				token,
				generation
			)
			.run();
		if (databaseChanges(completed) === 0) {
			await removeShareGeneration(env, token, generation);
			return;
		}
		await removeOldShareGenerations(env, token, generation);
	} catch (error) {
		await env.DB.prepare(
			'UPDATE share_links\n' +
				'SET status = \'failed\', error_message = ?, updated_at = ?\n' +
				'WHERE token = ? AND generation = ?'
		)
			.bind(
				error instanceof Error ? error.message : 'The share link could not be prepared.',
				new Date().toISOString(),
				token,
				generation
			)
			.run();
	}
}

async function ownerShareLinkStatus(request, env) {
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	const captureID = new URL(request.url).searchParams.get('captureID');
	if (!captureID) {
		const result = await shareLinksForOwner(env, email);
		return json({
			limit: maximumActiveShareLinks,
			links: (result.results ?? []).map((record) => ({
				...shareLinkResponse(request, record),
				captureID: record.capture_id
			}))
		});
	}
	if (!validCaptureIdentifier(captureID)) {
		return json({ error: 'Choose a valid personal library document.' }, { status: 400 });
	}
	return json(shareLinkResponse(request, await shareLinkForOwner(env, email, captureID)));
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

async function publicContentReport(request, env, token) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const share = await shareLinkByToken(env, token);
	if (!share) return json({ error: 'This share link is no longer available.' }, { status: 404 });
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid content report.' }, { status: 400 });
	}
	try {
		const category = contentReportString(value?.category, 32, true);
		if (!contentReportCategories.has(category)) throw new Error('Choose a valid report reason.');
		const childSafety = category === 'child-safety';
		const reporterName = contentReportString(value?.reporterName, 200, !childSafety);
		const reporterEmail = contentReportString(value?.reporterEmail, 254, !childSafety);
		if (reporterEmail && !emailAddressPattern.test(reporterEmail)) {
			throw new Error('Enter a valid email address.');
		}
		const workDescription = contentReportString(
			value?.workDescription,
			2_000,
			category === 'copyright'
		);
		const explanation = contentReportString(value?.explanation, 5_000, true);
		const variant = value?.variant;
		if (variant !== undefined && !shareVariants.includes(variant)) {
			throw new Error('Choose a valid document version.');
		}
		if (value?.goodFaith !== true) {
			throw new Error('Confirm that the report is accurate and complete.');
		}
		let metadata = {};
		try {
			metadata = JSON.parse(share.metadata_json ?? '{}');
		} catch {
			metadata = {};
		}
		const id = crypto.randomUUID();
		const createdAt = Date.now();
		const inserted = await env.DB.prepare(
			'INSERT INTO content_reports (\n' +
				'	id, share_token, owner_email, capture_id, share_title, reported_url,\n' +
				'	variant, category, reporter_name, reporter_email, work_description,\n' +
				'	explanation, status, created_at\n' +
				')\n' +
				'SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, \'open\', ?\n' +
				'WHERE (\n' +
				'	SELECT COUNT(*) FROM content_reports\n' +
				'	WHERE share_token = ? AND created_at >= ?\n' +
				') < ?'
		)
			.bind(
				id,
				token,
				share.owner_email,
				share.capture_id,
				String(metadata.title ?? 'Shared document').slice(0, 500),
				shareLinkURL(request, token),
				variant ?? null,
				category,
				reporterName ?? null,
				reporterEmail ?? null,
				workDescription ?? null,
				explanation,
				createdAt,
				token,
				createdAt - 24 * 60 * 60 * 1000,
				maximumContentReportsPerSharePerDay
			)
			.run();
		if (databaseChanges(inserted) !== 1) {
			return json(
				{ error: 'This share has received many recent reports. Email hello@readbriefly.fyi.' },
				{ status: 429 }
			);
		}
		return json({ id, receivedAt: new Date(createdAt).toISOString() }, { status: 201 });
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : 'Invalid content report.' },
			{ status: 400 }
		);
	}
}

async function publishShareLink(request, env, context) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid share-link request.' }, { status: 400 });
	}
	const captureID = value?.captureID;
	if (!validCaptureIdentifier(captureID)) {
		return json({ error: 'Choose a valid personal library document.' }, { status: 400 });
	}
	const removed = await env.DB.prepare(
		'SELECT id FROM content_reports\n' +
			'WHERE owner_email = ? AND capture_id = ? AND status = \'removed\'\n' +
			'LIMIT 1'
	)
		.bind(email, captureID)
		.first();
	if (removed) {
		return json(
			{
				error: 'This document was removed after content report ' +
					removed.id +
					'. Email hello@readbriefly.fyi to appeal.'
			},
			{ status: 403 }
		);
	}
	let source;
	try {
		source = directShareSource(value?.source, captureID);
	} catch (error) {
		return json(
			{ error: error instanceof Error ? error.message : 'The selected document is invalid.' },
			{ status: 400 }
		);
	}
	if (!source) return json({ error: 'Include the document to publish.' }, { status: 400 });
	const token = randomBase64URL(24);
	const generation = crypto.randomUUID();
	const now = new Date().toISOString();
	const published = await env.DB.prepare(
		'INSERT INTO share_links (\n' +
			'	token, owner_email, capture_id, generation, revision, status,\n' +
			'	metadata_json, source_filename, error_message, created_at, updated_at\n' +
			')\n' +
			'SELECT ?, ?, ?, ?, 1, \'preparing\', NULL, NULL, NULL, ?, ?\n' +
			'WHERE EXISTS (\n' +
			'	SELECT 1 FROM share_links WHERE owner_email = ? AND capture_id = ?\n' +
			') OR (\n' +
			'	SELECT COUNT(*) FROM share_links WHERE owner_email = ?\n' +
			') < ?\n' +
			'ON CONFLICT(owner_email, capture_id) DO UPDATE SET\n' +
			'	generation = excluded.generation,\n' +
			'	revision = share_links.revision + 1,\n' +
			'	status = \'preparing\',\n' +
			'	error_message = NULL,\n' +
			'	updated_at = excluded.updated_at'
	)
		.bind(
			token,
			email,
			captureID,
			generation,
			now,
			now,
			email,
			captureID,
			email,
			maximumActiveShareLinks
		)
		.run();
	if (Number(published?.meta?.changes ?? 0) === 0) {
		return json(
			{
				error: 'You can publish up to ' +
					maximumActiveShareLinks +
					' active links. Stop sharing one before creating another.',
				code: 'share_limit_reached'
			},
			{ status: 409 }
		);
	}
	const record = await shareLinkForOwner(env, email, captureID);
	scheduleSharingOperation(
		context,
		prepareShareLink(env, email, record.token, captureID, generation, source)
	);
	return json(shareLinkResponse(request, record), { status: 202 });
}

async function revokeShareLink(request, env, token, context) {
	void context;
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	const record = await shareLinkByToken(env, token);
	if (!record || record.owner_email !== email) {
		return json({ error: 'Share link not found.' }, { status: 404 });
	}
	await env.DB.batch([
		env.DB.prepare('DELETE FROM share_texts WHERE share_token = ?').bind(token),
		env.DB.prepare('DELETE FROM share_links WHERE token = ? AND owner_email = ?').bind(token, email)
	]);
	return json({ revoked: true });
}

async function publicShareDocument(request, env, token) {
	const record = await shareLinkByToken(env, token);
	if (!record) return json({ error: 'This share link is no longer available.' }, { status: 404 });
	if (record.status !== 'ready') {
		return json(
			{
				status: record.status,
				error: record.status === 'failed' ? record.error_message : undefined
			},
			{ status: record.status === 'preparing' ? 202 : 409 }
		);
	}
	const textResult = await env.DB.prepare(
		'SELECT variant, markdown, word_count FROM share_texts\n' +
			'WHERE share_token = ? AND generation = ? AND variant <> \'source\''
	)
		.bind(token, record.generation)
		.all();
	let metadata = {};
	try {
		metadata = JSON.parse(record.metadata_json ?? '{}');
	} catch {
		metadata = {};
	}
	const texts = (textResult.results ?? [])
		.filter((document) => shareVariants.includes(document.variant))
		.map((document) => ({
			variant: document.variant,
			markdown: document.markdown,
			wordCount: Number(document.word_count ?? 0)
		}))
		.sort(
			(a, b) => shareVariants.indexOf(a.variant) - shareVariants.indexOf(b.variant)
		);
	return json({
		status: 'ready',
		token,
		revision: Number(record.revision ?? 1),
		...metadata,
		texts,
		updatedAt: record.updated_at
	});
}

export {
	ownerShareLinkStatus,
	publishShareLink,
	publicContentReport,
	publicShareDocument,
	revokeShareLink,
	shareLinkURL
};
