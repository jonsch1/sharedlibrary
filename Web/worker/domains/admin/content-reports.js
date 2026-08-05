import { json, requireSameOrigin } from '../../infrastructure/http-security.js';
import { uuidPattern } from '../../infrastructure/input-validation.js';
import { administratorRequest } from './access.js';

async function adminContentReports(request, env, context) {
	void context;
	const administrator = await administratorRequest(request, env);
	if (administrator.response) return administrator.response;
	if (request.method === 'GET') {
		const result = await env.DB.prepare(
			'SELECT id, share_token, owner_email, capture_id, share_title, reported_url,\n' +
				'       variant, category, reporter_name, reporter_email, work_description,\n' +
				'       explanation, status, created_at, resolved_at\n' +
				'FROM content_reports\n' +
				'ORDER BY CASE status WHEN \'open\' THEN 0 ELSE 1 END, created_at DESC\n' +
				'LIMIT 100'
		).all();
		return json({
			reports: (result.results ?? []).map((report) => ({
				id: report.id,
				shareToken: report.share_token,
				ownerEmail: report.owner_email,
				captureID: report.capture_id,
				shareTitle: report.share_title,
				reportedURL: report.reported_url,
				variant: report.variant ?? undefined,
				category: report.category,
				reporterName: report.reporter_name ?? undefined,
				reporterEmail: report.reporter_email ?? undefined,
				workDescription: report.work_description ?? undefined,
				explanation: report.explanation,
				status: report.status,
				createdAt: Number(report.created_at),
				resolvedAt: report.resolved_at === null ? undefined : Number(report.resolved_at)
			}))
		});
	}
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid report decision.' }, { status: 400 });
	}
	if (!uuidPattern.test(value?.id ?? '') || !['removed', 'no-action'].includes(value?.decision)) {
		return json({ error: 'Invalid report decision.' }, { status: 400 });
	}
	const report = await env.DB.prepare(
		'SELECT id, share_token, owner_email, capture_id\n' +
			'FROM content_reports WHERE id = ?'
	)
		.bind(value.id)
		.first();
	if (!report) return json({ error: 'Content report not found.' }, { status: 404 });
	const resolvedAt = Date.now();
	if (value.decision === 'removed') {
		const message =
			'This public share was removed after content report ' +
			report.id +
			'. Email hello@readbriefly.fyi to appeal.';
		await env.DB.batch([
			env.DB.prepare('DELETE FROM share_texts WHERE share_token = ?').bind(report.share_token),
			env.DB.prepare(
				'UPDATE share_links\n' +
					'SET status = \'failed\', error_message = ?, updated_at = ?\n' +
					'WHERE token = ?'
			).bind(message, new Date(resolvedAt).toISOString(), report.share_token),
			env.DB.prepare(
				'UPDATE content_reports\n' +
					'SET status = \'removed\', resolved_at = ? WHERE id = ?'
			).bind(resolvedAt, report.id)
		]);
	} else {
		await env.DB.prepare(
			'UPDATE content_reports\n' +
				'SET status = \'no-action\', resolved_at = ? WHERE id = ?'
		)
			.bind(resolvedAt, report.id)
			.run();
	}
	return json({ id: report.id, status: value.decision, resolvedAt });
}

export { adminContentReports };
