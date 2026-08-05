import { databaseChanges } from '../../infrastructure/database.js';
import { json, requestJSON } from '../../infrastructure/http-security.js';
import { randomBase64URL } from '../../infrastructure/crypto.js';
import { authenticatedEmail, authenticatedMutation } from '../auth/session.js';
import {
	directShareSource,
	maximumActiveShareLinks,
	scheduleSharingOperation,
	validCaptureIdentifier
} from './validation.js';
import {
	prepareShareLink,
	shareLinkByToken,
	shareLinkForOwner,
	shareLinkResponse,
	shareLinksForOwner
} from './repository.js';

async function ownerShareLinkStatus(request, env) {
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	const captureID = new URL(request.url).searchParams.get('captureID');
	if (!captureID) {
		const result = await shareLinksForOwner(env, email, maximumActiveShareLinks);
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

async function publishShareLink(request, env, context) {
	const authentication = await authenticatedMutation(request, env);
	if (authentication.response) return authentication.response;
	const { email } = authentication;
	const value = await requestJSON(request);
	if (value === undefined) {
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
			'\ttoken, owner_email, capture_id, generation, revision, status,\n' +
			'\tmetadata_json, source_filename, error_message, created_at, updated_at\n' +
			')\n' +
			'SELECT ?, ?, ?, ?, 1, \'preparing\', NULL, NULL, NULL, ?, ?\n' +
			'WHERE EXISTS (\n' +
			'\tSELECT 1 FROM share_links WHERE owner_email = ? AND capture_id = ?\n' +
			') OR (\n' +
			'\tSELECT COUNT(*) FROM share_links WHERE owner_email = ?\n' +
			') < ?\n' +
			'ON CONFLICT(owner_email, capture_id) DO UPDATE SET\n' +
			'\tgeneration = excluded.generation,\n' +
			'\trevision = share_links.revision + 1,\n' +
			'\tstatus = \'preparing\',\n' +
			'\terror_message = NULL,\n' +
			'\tupdated_at = excluded.updated_at'
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
	const authentication = await authenticatedMutation(request, env);
	if (authentication.response) return authentication.response;
	const { email } = authentication;
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

export { ownerShareLinkStatus, publishShareLink, revokeShareLink };
