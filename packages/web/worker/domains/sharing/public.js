import { databaseChanges } from '../../infrastructure/database.js';
import { emailAddressPattern } from '../../infrastructure/input-validation.js';
import { json, requestJSON, sameOriginResponse } from '../../infrastructure/http-security.js';
import {
	contentReportCategories,
	contentReportString,
	maximumContentReportsPerSharePerDay,
	shareLinkURL,
	shareVariants,
	sourceVariant
} from './validation.js';
import { shareLinkByToken } from './repository.js';

async function publicContentReport(request, env, token) {
	const originError = sameOriginResponse(request);
	if (originError) return originError;
	const share = await shareLinkByToken(env, token);
	if (!share) return json({ error: 'This share link is no longer available.' }, { status: 404 });
	const value = await requestJSON(request);
	if (value === undefined) {
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
				'\tid, share_token, owner_email, capture_id, share_title, reported_url,\n' +
				'\tvariant, category, reporter_name, reporter_email, work_description,\n' +
				'\texplanation, status, created_at\n' +
				')\n' +
				'SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, \'open\', ?\n' +
				'WHERE (\n' +
				'\tSELECT COUNT(*) FROM content_reports\n' +
				'\tWHERE share_token = ? AND created_at >= ?\n' +
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

async function publicShareDocument(request, env, token) {
	// Read metadata and its text generation from one SQLite snapshot.
	const result = await env.DB.prepare(
		'SELECT link.token, link.status, link.revision, link.metadata_json,\n' +
			'       link.error_message, link.updated_at, text.variant, text.markdown, text.word_count\n' +
			'FROM share_links link LEFT JOIN share_texts text\n' +
			'    ON text.share_token = link.token AND text.generation = link.generation\n' +
			'    AND text.variant <> ?\n' +
			'WHERE link.token = ?'
	).bind(sourceVariant, token).all();
	const record = result.results?.[0];
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
	let metadata = {};
	try {
		metadata = JSON.parse(record.metadata_json ?? '{}');
	} catch {
		metadata = {};
	}
	const texts = (result.results ?? [])
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

export { publicContentReport, publicShareDocument };
