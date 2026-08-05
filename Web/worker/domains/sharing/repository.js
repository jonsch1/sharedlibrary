import { databaseChanges } from '../../infrastructure/database.js';
import { shareLinkURL, maximumShareTextBytesPerAccount, validateShareDocuments } from './validation.js';

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

async function shareLinksForOwner(env, email, maximumActiveShareLinks) {
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
					'\tshare_token, generation, variant, markdown, word_count\n' +
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

export {
	ownerShareTextBytes,
	prepareShareLink,
	removeOldShareGenerations,
	removeShareGeneration,
	shareLinkByToken,
	shareLinkForOwner,
	shareLinkResponse,
	shareLinksForOwner
};
