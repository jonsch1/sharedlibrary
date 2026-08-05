import {
	databaseChanges,
	emailAddressPattern,
	json,
	normalizedEmail,
	requireSameOrigin,
	uuidPattern
} from './http-security.js';
import {
	accountRecord,
	authenticatedEmail,
	isAdministrator
} from './auth-accounts.js';
import { quotaResponse, serviceUsageLimits } from './ai-service-usage.js';

const maximumFeedbackItemsPerAccount = 10;
const maximumFeedbackItemsPerDay = 3;

async function administratorRequest(request, env) {
	const email = await authenticatedEmail(request, env);
	if (!email) {
		return { response: json({ error: 'Authentication required.' }, { status: 401 }) };
	}
	if (!isAdministrator(email)) {
		return {
			response: json({ error: 'Administrator access required.' }, { status: 403 })
		};
	}
	return { email };
}

async function adminComplimentaryAccess(request, env) {
	const administrator = await administratorRequest(request, env);
	if (administrator.response) return administrator.response;
	if (request.method === 'GET') {
		const result = await env.DB.prepare(
			'SELECT user_email, granted_by, created_at\n' +
				'FROM complimentary_access\n' +
				'ORDER BY created_at DESC, user_email'
		).all();
		return json({
			emails: (result.results ?? []).map((entry) => ({
				email: entry.user_email,
				grantedBy: entry.granted_by,
				createdAt: Number(entry.created_at)
			}))
		});
	}
	if (!requireSameOrigin(request)) {
		return json({ error: 'Invalid request origin.' }, { status: 403 });
	}
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid access request.' }, { status: 400 });
	}
	const email = normalizedEmail(value?.email);
	if (email.length > 254 || !emailAddressPattern.test(email)) {
		return json({ error: 'Enter a valid email address.' }, { status: 400 });
	}
	if (request.method === 'POST') {
		const createdAt = Date.now();
		const result = await env.DB.prepare(
			'INSERT OR IGNORE INTO complimentary_access (user_email, granted_by, created_at)\n' +
				'VALUES (?, ?, ?)'
		)
			.bind(email, normalizedEmail(administrator.email), createdAt)
			.run();
		return json(
			{ email, createdAt, created: databaseChanges(result) === 1 },
			{ status: databaseChanges(result) === 1 ? 201 : 200 }
		);
	}
	if (request.method === 'DELETE') {
		const result = await env.DB.prepare(
			'DELETE FROM complimentary_access WHERE user_email = ?'
		)
			.bind(email)
			.run();
		return json({ email, removed: databaseChanges(result) === 1 });
	}
	return json({ error: 'Method not allowed.' }, { status: 405 });
}

async function adminUsage(request, env) {
	const administrator = await administratorRequest(request, env);
	if (administrator.response) return administrator.response;
	if (request.method === 'GET') {
		const day = new Date().toISOString().slice(0, 10);
		const month = day.slice(0, 7) + '-01';
		const accounts = await env.DB.prepare(
			'SELECT user_email, account_id FROM accounts ORDER BY user_email'
		).all();
		const usage = await env.DB.prepare(
			'SELECT account_id, service,\n' +
				'       MAX(CASE WHEN usage_day = ? THEN units ELSE 0 END) AS daily_units,\n' +
				'       SUM(units) AS monthly_units\n' +
				'FROM service_usage\n' +
				'WHERE usage_day >= ?\n' +
				'GROUP BY account_id, service'
		)
			.bind(day, month)
			.all();
		const overrides = await env.DB.prepare(
			'SELECT account_id, service, daily_units, monthly_units, concurrency\n' +
				'FROM service_limit_overrides'
		).all();
		const leases = await env.DB.prepare(
			'SELECT account_id, service, COUNT(*) AS active_leases\n' +
				'FROM service_leases\n' +
				'WHERE expires_at > ?\n' +
				'GROUP BY account_id, service'
		)
			.bind(Date.now())
			.all();
		const usageByService = new Map(
			(usage.results ?? []).map((entry) => [
				entry.account_id + ':' + entry.service,
				entry
			])
		);
		const overrideByService = new Map(
			(overrides.results ?? []).map((entry) => [
				entry.account_id + ':' + entry.service,
				entry
			])
		);
		const leasesByService = new Map(
			(leases.results ?? []).map((entry) => [
				entry.account_id + ':' + entry.service,
				entry
			])
		);
		return json({
			accounts: (accounts.results ?? []).map((account) => ({
				email: account.user_email,
				services: Object.entries(serviceUsageLimits).map(([service, defaults]) => {
					const key = account.account_id + ':' + service;
					const used = usageByService.get(key);
					const override = overrideByService.get(key);
					return {
						service,
						usage: {
							dailyUnits: Number(used?.daily_units ?? 0),
							monthlyUnits: Number(used?.monthly_units ?? 0),
							activeLeases: Number(leasesByService.get(key)?.active_leases ?? 0)
						},
						limits: {
							dailyUnits: Number(override?.daily_units ?? defaults.dailyUnits),
							monthlyUnits: Number(override?.monthly_units ?? defaults.monthlyUnits),
							concurrency: Number(override?.concurrency ?? defaults.concurrency)
						},
						custom: Boolean(override)
					};
				})
			}))
		});
	}
	if (!requireSameOrigin(request)) {
		return json({ error: 'Invalid request origin.' }, { status: 403 });
	}
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid usage limit request.' }, { status: 400 });
	}
	const email = normalizedEmail(value?.email);
	const service = typeof value?.service === 'string' ? value.service : '';
	const defaults = serviceUsageLimits[service];
	if (email.length > 254 || !emailAddressPattern.test(email) || !defaults) {
		return json({ error: 'Choose a valid account and service.' }, { status: 400 });
	}
	const account = await accountRecord(env, email);
	if (!account) return json({ error: 'Account not found.' }, { status: 404 });
	if (request.method === 'DELETE') {
		await env.DB.prepare(
			'DELETE FROM service_limit_overrides WHERE account_id = ? AND service = ?'
		)
			.bind(account.account_id, service)
			.run();
		return json({
			email,
			service,
			limits: {
				dailyUnits: defaults.dailyUnits,
				monthlyUnits: defaults.monthlyUnits,
				concurrency: defaults.concurrency
			},
			custom: false
		});
	}
	const limits = value?.limits;
	if (
		![limits?.dailyUnits, limits?.monthlyUnits, limits?.concurrency].every(
			(limit) => Number.isSafeInteger(limit) && limit >= 0
		)
	) {
		return json({ error: 'Limits must be non-negative whole numbers.' }, { status: 400 });
	}
	await env.DB.prepare(
		'INSERT INTO service_limit_overrides (\n' +
			'	account_id, service, daily_units, monthly_units, concurrency, updated_at\n' +
			') VALUES (?, ?, ?, ?, ?, ?)\n' +
			'ON CONFLICT(account_id, service) DO UPDATE SET\n' +
			'	daily_units = excluded.daily_units,\n' +
			'	monthly_units = excluded.monthly_units,\n' +
			'	concurrency = excluded.concurrency,\n' +
			'	updated_at = excluded.updated_at'
	)
		.bind(
			account.account_id,
			service,
			limits.dailyUnits,
			limits.monthlyUnits,
			limits.concurrency,
			Date.now()
		)
		.run();
	return json({ email, service, limits, custom: true });
}

async function feedbackBoard(request, env) {
	const email = await authenticatedEmail(request, env);
	const result = await env.DB.prepare(
		'SELECT\n' +
			'	item.id,\n' +
			'	item.title,\n' +
			'	item.details,\n' +
			'	item.created_at,\n' +
			'	COUNT(upvote.user_email) AS upvotes,\n' +
			'	MAX(CASE WHEN upvote.user_email = ? THEN 1 ELSE 0 END) AS upvoted\n' +
			'FROM feedback_items item\n' +
			'LEFT JOIN feedback_upvotes upvote ON upvote.feedback_item_id = item.id\n' +
			'GROUP BY item.id\n' +
			'ORDER BY upvotes DESC, item.created_at DESC\n' +
			'LIMIT 200'
	)
		.bind(email ?? '')
		.all();
	return json({
		authenticated: Boolean(email),
		items: (result.results ?? []).map((item) => ({
			id: item.id,
			title: item.title,
			details: item.details,
			createdAt: Number(item.created_at),
			upvotes: Number(item.upvotes),
			upvoted: Boolean(item.upvoted)
		}))
	});
}

async function createFeedback(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid feedback request.' }, { status: 400 });
	}
	const title = typeof value?.title === 'string' ? value.title.trim() : '';
	const details = typeof value?.details === 'string' ? value.details.trim() : '';
	if (title.length < 3 || title.length > 120 || details.length > 2_000) {
		return json(
			{ error: 'Use a title between 3 and 120 characters and details under 2,000 characters.' },
			{ status: 400 }
		);
	}
	const item = {
		id: crypto.randomUUID(),
		title,
		details,
		createdAt: Date.now(),
		upvotes: 1,
		upvoted: true
	};
	const inserted = await env.DB.prepare(
		'INSERT INTO feedback_items (id, user_email, title, details, created_at)\n' +
			'SELECT ?, ?, ?, ?, ?\n' +
			'WHERE (SELECT COUNT(*) FROM feedback_items WHERE user_email = ?) < ?\n' +
			'  AND (\n' +
			'	SELECT COUNT(*) FROM feedback_items\n' +
			'	WHERE user_email = ? AND created_at >= ?\n' +
			'  ) < ?'
	)
		.bind(
			item.id,
			email,
			title,
			details,
			item.createdAt,
			email,
			maximumFeedbackItemsPerAccount,
			email,
			item.createdAt - 24 * 60 * 60 * 1000,
			maximumFeedbackItemsPerDay
		)
		.run();
	if (databaseChanges(inserted) !== 1) {
		return quotaResponse('You can submit up to three feedback items per day.');
	}
	await env.DB.prepare(
		'INSERT INTO feedback_upvotes (feedback_item_id, user_email, created_at)\n' +
			'VALUES (?, ?, ?)'
	)
		.bind(item.id, email, item.createdAt)
		.run();
	return json(item, { status: 201 });
}

async function setFeedbackUpvote(request, env, itemID) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const email = await authenticatedEmail(request, env);
	if (!email) return json({ error: 'Authentication required.' }, { status: 401 });
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid upvote request.' }, { status: 400 });
	}
	if (typeof value?.upvoted !== 'boolean') {
		return json({ error: 'Invalid upvote request.' }, { status: 400 });
	}
	const statement = value.upvoted
		? env.DB.prepare(
				'INSERT OR IGNORE INTO feedback_upvotes (feedback_item_id, user_email, created_at)\n' +
					'SELECT ?, ?, ? FROM feedback_items WHERE id = ?'
			).bind(itemID, email, Date.now(), itemID)
		: env.DB.prepare(
				'DELETE FROM feedback_upvotes WHERE feedback_item_id = ? AND user_email = ?'
			).bind(itemID, email);
	await statement.run();
	const result = await env.DB.prepare(
		'SELECT\n' +
			'	COUNT(*) AS upvotes,\n' +
			'	MAX(CASE WHEN user_email = ? THEN 1 ELSE 0 END) AS upvoted\n' +
			'FROM feedback_upvotes\n' +
			'WHERE feedback_item_id = ?'
	)
		.bind(email, itemID)
		.first();
	return json({
		id: itemID,
		upvotes: Number(result?.upvotes ?? 0),
		upvoted: Boolean(result?.upvoted)
	});
}

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

export {
	adminComplimentaryAccess,
	adminContentReports,
	adminUsage,
	feedbackBoard,
	createFeedback,
	setFeedbackUpvote
};
