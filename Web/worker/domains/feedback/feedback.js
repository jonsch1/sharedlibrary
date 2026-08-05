import { databaseChanges } from '../../infrastructure/database.js';
import { json, requireSameOrigin } from '../../infrastructure/http-security.js';
import { authenticatedEmail } from '../auth/session.js';

const maximumFeedbackItemsPerAccount = 10;
const maximumFeedbackItemsPerDay = 3;

function feedbackQuotaResponse(message) {
	return json(
		{ error: message, code: 'usage_limit_reached' },
		{ status: 429, headers: { 'Retry-After': '3600' } }
	);
}

async function feedbackBoard(request, env) {
	const email = await authenticatedEmail(request, env);
	const result = await env.DB.prepare(
		'SELECT\n' +
			'\titem.id,\n' +
			'\titem.title,\n' +
			'\titem.details,\n' +
			'\titem.created_at,\n' +
			'\tCOUNT(upvote.user_email) AS upvotes,\n' +
			'\tMAX(CASE WHEN upvote.user_email = ? THEN 1 ELSE 0 END) AS upvoted\n' +
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
			'\tSELECT COUNT(*) FROM feedback_items\n' +
			'\tWHERE user_email = ? AND created_at >= ?\n' +
			'  ) < ?'
	)
		.bind(
			item.id,
			email,
			item.title,
			item.details,
			item.createdAt,
			email,
			maximumFeedbackItemsPerAccount,
			email,
			item.createdAt - 24 * 60 * 60 * 1000,
			maximumFeedbackItemsPerDay
		)
		.run();
	if (databaseChanges(inserted) !== 1) {
		return feedbackQuotaResponse('You can submit up to three feedback items per day.');
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
			'\tCOUNT(*) AS upvotes,\n' +
			'\tMAX(CASE WHEN user_email = ? THEN 1 ELSE 0 END) AS upvoted\n' +
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

export { createFeedback, feedbackBoard, setFeedbackUpvote };
