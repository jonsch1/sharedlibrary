import {
	databaseChanges,
	json,
	requireSameOrigin
} from './http-security.js';
import {
	accountRecord,
	activeAppStoreSubscription,
	authenticatedEmail,
	ensureAccount,
	hasComplimentaryPlusAccess,
	paidAccessResponse
} from './auth-accounts.js';

const managedAIModel = 'openai/gpt-5.6-luna';
const managedAIMonthlyAllowanceMicros = 5_000_000;
const managedAIReservationMicros = 500_000;
const managedAIUpstreamTimeoutMilliseconds = 15 * 60 * 1000;
const managedAIReservationStaleMilliseconds = 20 * 60 * 1000;
const maximumManagedAIPromptLength = 600_000;
const firecrawlEndpoint = 'https://api.firecrawl.dev/v2/scrape';

const serviceUsageLimits = {
	transcription: {
		dailyUnits: 8 * 60 * 60,
		monthlyUnits: 50 * 60 * 60,
		concurrency: 2,
		leaseMilliseconds: 35 * 60 * 1000
	},
	voice: {
		dailyUnits: 250_000,
		monthlyUnits: 2_000_000,
		concurrency: 1,
		leaseMilliseconds: 35 * 60 * 1000
	},
	firecrawl: {
		dailyUnits: 250,
		monthlyUnits: 500,
		concurrency: 2,
		leaseMilliseconds: 3 * 60 * 1000
	},
	media: {
		dailyUnits: 2_000_000_000,
		monthlyUnits: 10_000_000_000,
		concurrency: 2,
		leaseMilliseconds: 10 * 60 * 1000
	}
};

const managedAIJSONSchema = {
	name: 'briefly_processing',
	strict: true,
	schema: {
		type: 'object',
		additionalProperties: false,
		properties: {
			short_filename: { type: 'string' },
			summaries: {
				type: 'object',
				additionalProperties: false,
				properties: {
					detailed: { type: 'string' },
					concise: { type: 'string' }
				},
				required: ['detailed', 'concise']
			},
			topic_name: { type: 'string' }
		},
		required: ['short_filename', 'summaries', 'topic_name']
	}
};

function managedAIKey(env) {
	const apiKey = String(env.OPENROUTER_API_KEY || '').trim();
	return apiKey || null;
}

async function scrapeWithFirecrawl(request, env) {
	if (!requireSameOrigin(request)) return json({ error: 'Invalid request origin.' }, { status: 403 });
	const denied = await paidAccessResponse(request, env);
	if (denied) return denied;
	if (!paidProcessingEnabled(env)) {
		return json({ error: 'Web extraction is temporarily paused.' }, { status: 503 });
	}
	let rawURL;
	try {
		rawURL = (await request.json()).url;
		const url = new URL(rawURL);
		if (
			(url.protocol !== 'http:' && url.protocol !== 'https:') ||
			url.username ||
			url.password ||
			rawURL.length > 8_192
		) {
			throw new Error();
		}
		rawURL = url.toString();
	} catch {
		return json({ error: 'Invalid extraction URL.' }, { status: 400 });
	}
	const email = await authenticatedEmail(request, env);
	const customer = email ? await ensureAccount(env, email) : null;
	if (!customer) return json({ error: 'Authentication required.' }, { status: 401 });
	const limits = await accountServiceLimits(env, customer.account_id, 'firecrawl');
	const leaseID = await reserveServiceLease(
		env,
		customer.account_id,
		'firecrawl',
		limits
	);
	if (!leaseID) return quotaResponse('Too many web extractions are already running.');
	const usage = await consumeServiceUnits(
		env,
		customer.account_id,
		'firecrawl',
		5,
		limits
	);
	if (!usage) {
		await releaseServiceLease(env, customer.account_id, 'firecrawl', leaseID);
		return quotaResponse('The monthly web-extraction allowance has been reached.');
	}
	const apiKey = String(env.FIRECRAWL_API_KEY || '').trim();
	if (!apiKey) {
		await releaseServiceLease(env, customer.account_id, 'firecrawl', leaseID);
		return json({ error: 'Web extraction is unavailable.' }, { status: 503 });
	}
	try {
		const response = await fetch(firecrawlEndpoint, {
			method: 'POST',
			headers: {
				Authorization: 'Bearer ' + apiKey,
				'Content-Type': 'application/json'
			},
			body: JSON.stringify({
				url: rawURL,
				formats: ['markdown'],
				onlyMainContent: true,
				removeBase64Images: true,
				storeInCache: false,
				timeout: 120_000
			})
		});
		return new Response(response.body, {
			status: response.status,
			headers: {
				'Cache-Control': 'no-store',
				'Content-Type': response.headers.get('Content-Type') || 'application/json'
			}
		});
	} finally {
		await releaseServiceLease(env, customer.account_id, 'firecrawl', leaseID);
	}
}

async function reserveManagedAIUsage(env, accountID, usageMonth, allowanceMicros) {
	const now = Date.now();
	await env.DB.prepare(
		'INSERT OR IGNORE INTO managed_ai_usage (\n' +
			'account_id, usage_month, spent_micros, reserved_micros, updated_at\n' +
			') VALUES (?, ?, 0, 0, ?)'
	)
		.bind(accountID, usageMonth, now)
		.run();
	const result = await env.DB.prepare(
		'UPDATE managed_ai_usage\n' +
			'SET reserved_micros = CASE\n' +
			'      WHEN updated_at < ? THEN ?\n' +
			'      ELSE reserved_micros + ?\n' +
			'    END,\n' +
			'    reservation_id = NULL,\n' +
			'    updated_at = ?\n' +
			'WHERE account_id = ? AND usage_month = ?\n' +
			'  AND spent_micros + CASE\n' +
			'        WHEN updated_at < ? THEN 0\n' +
			'        ELSE reserved_micros\n' +
			'      END + ? <= ?'
	)
		.bind(
			now - managedAIReservationStaleMilliseconds,
			managedAIReservationMicros,
			managedAIReservationMicros,
			now,
			accountID,
			usageMonth,
			now - managedAIReservationStaleMilliseconds,
			managedAIReservationMicros,
			allowanceMicros
		)
		.run();
	const usage = await env.DB.prepare(
		'SELECT spent_micros, reserved_micros\n' +
			'FROM managed_ai_usage\n' +
			'WHERE account_id = ? AND usage_month = ?'
	)
		.bind(accountID, usageMonth)
		.first();
	return {
		reserved: databaseChanges(result) > 0,
		spentMicros: Number(usage?.spent_micros ?? 0),
		reservedMicros: Number(usage?.reserved_micros ?? 0),
		reservationMicros: managedAIReservationMicros
	};
}

async function releaseManagedAIUsage(env, accountID, usageMonth, reservationMicros) {
	await env.DB.prepare(
		'UPDATE managed_ai_usage\n' +
			'SET reserved_micros = MAX(0, reserved_micros - ?), updated_at = ?\n' +
			'WHERE account_id = ? AND usage_month = ?'
	)
		.bind(reservationMicros, Date.now(), accountID, usageMonth)
		.run();
}

async function settleManagedAIUsage(
	env,
	accountID,
	usageMonth,
	reservationMicros,
	costMicros,
	allowanceMicros
) {
	await env.DB.prepare(
		'UPDATE managed_ai_usage\n' +
			'SET spent_micros = MIN(?, spent_micros + ?),\n' +
			'    reserved_micros = MAX(0, reserved_micros - ?),\n' +
			'    updated_at = ?\n' +
			'WHERE account_id = ? AND usage_month = ?'
	)
		.bind(
			allowanceMicros,
			costMicros,
			reservationMicros,
			Date.now(),
			accountID,
			usageMonth
		)
		.run();
}

async function processWithManagedAI(request, env) {
	if (!requireSameOrigin(request)) {
		return json({ error: 'Invalid request origin.' }, { status: 403 });
	}
	const email = await authenticatedEmail(request, env);
	if (!email) {
		return json(
			{ error: 'Sign in before using Briefly AI.', code: 'authentication_required' },
			{ status: 401 }
		);
	}
	const apiKey = managedAIKey(env);
	if (!apiKey) {
		return json({ error: 'Briefly AI is unavailable.' }, { status: 503 });
	}
	const complimentary = await hasComplimentaryPlusAccess(env, email);
	let customer = await accountRecord(env, email);
	if (!complimentary && !(await activeAppStoreSubscription(env, customer?.account_id))) {
		return json(
			{
				error: 'An active Briefly membership is required for Briefly AI.',
				code: 'subscription_required'
			},
			{ status: 402 }
		);
	}
	customer ??= await ensureAccount(env, email);

	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid AI request.' }, { status: 400 });
	}
	const prompt = typeof value.prompt === 'string' ? value.prompt.trim() : '';
	const format = value.format === 'json' || value.format === 'text' ? value.format : null;
	if (!prompt || prompt.length > maximumManagedAIPromptLength || !format) {
		return json({ error: 'Invalid AI prompt or output format.' }, { status: 400 });
	}

	const allowanceMicros = managedAIMonthlyAllowanceMicros;
	const usageMonth = new Date().toISOString().slice(0, 7);
	const reservation = await reserveManagedAIUsage(
		env,
		customer.account_id,
		usageMonth,
		allowanceMicros
	);
	if (!reservation.reserved) {
		return json(
			{
				error: 'Your Briefly AI allowance resets next month.',
				code: 'monthly_limit_reached'
			},
			{ status: 429 }
		);
	}

	const upstreamController = new AbortController();
	const upstreamTimeout = setTimeout(
		() => upstreamController.abort(),
		managedAIUpstreamTimeoutMilliseconds
	);
	let reservationSettled = false;
	try {
		const response = await fetch('https://openrouter.ai/api/v1/chat/completions', {
			method: 'POST',
			signal: upstreamController.signal,
			headers: {
				Authorization: 'Bearer ' + apiKey,
				'Content-Type': 'application/json',
				'HTTP-Referer': 'https://www.readbriefly.fyi',
				'X-Title': 'Briefly'
			},
			body: JSON.stringify({
				model: managedAIModel,
				messages: [{ role: 'user', content: prompt }],
				max_tokens: format === 'json' ? 32_000 : 16_000,
				provider: {
					zdr: true,
					order: ['fireworks'],
					allow_fallbacks: true
				},
				...(format === 'json'
					? {
							response_format: {
								type: 'json_schema',
								json_schema: managedAIJSONSchema
							}
						}
					: {})
			})
		});
		if (!response.ok) {
			return json(
				{ error: 'Briefly AI via OpenRouter is temporarily unavailable.' },
				{ status: response.status }
			);
		}

		let result;
		try {
			result = await response.json();
		} catch {
			return json(
				{ error: 'Briefly AI via OpenRouter returned an invalid response.' },
				{ status: 502 }
			);
		}
		const reportedCost = Number(result?.usage?.cost);
		const costMicros =
			Number.isFinite(reportedCost) && reportedCost >= 0
				? Math.ceil(reportedCost * 1_000_000)
				: reservation.reservationMicros;
		await settleManagedAIUsage(
			env,
			customer.account_id,
			usageMonth,
			reservation.reservationMicros,
			costMicros,
			allowanceMicros
		);
		reservationSettled = true;
		const remainingMicros = Math.max(
			0,
			allowanceMicros -
				Math.min(allowanceMicros, reservation.spentMicros + costMicros)
		);
		const output = result?.choices?.[0]?.message?.content;
		if (typeof output !== 'string' || !output.trim()) {
			return json(
				{ error: 'Briefly AI via OpenRouter returned no output.' },
				{ status: 502 }
			);
		}
		return json({ output, remainingMicros });
	} catch {
		return json(
			{
				error: upstreamController.signal.aborted
					? 'Briefly AI timed out while waiting for OpenRouter.'
					: 'Briefly AI via OpenRouter is temporarily unavailable.'
			},
			{ status: upstreamController.signal.aborted ? 504 : 502 }
		);
	} finally {
		clearTimeout(upstreamTimeout);
		if (!reservationSettled) {
			await releaseManagedAIUsage(
				env,
				customer.account_id,
				usageMonth,
				reservation.reservationMicros
			);
		}
	}
}

function paidProcessingEnabled(env) {
	return String(env.PAID_PROCESSING_ENABLED ?? 'true').toLowerCase() !== 'false';
}

function quotaResponse(message) {
	return json(
		{ error: message, code: 'usage_limit_reached' },
		{ status: 429, headers: { 'Retry-After': '3600' } }
	);
}

async function serviceAccount(request, env) {
	const email = await authenticatedEmail(request, env);
	if (!email) {
		return {
			response: json(
				{ error: 'Sign in before using Briefly.', code: 'authentication_required' },
				{ status: 401 }
			)
		};
	}
	const record = await accountRecord(env, email);
	if (
		!(await hasComplimentaryPlusAccess(env, email)) &&
		!(await activeAppStoreSubscription(env, record?.account_id))
	) {
		return {
			response: json(
				{ error: 'An active Briefly membership is required.', code: 'subscription_required' },
				{ status: 402 }
			)
		};
	}
	return { email, customer: record ?? (await ensureAccount(env, email)) };
}

async function accountServiceLimits(env, accountID, service) {
	const defaults = serviceUsageLimits[service];
	const override = await env.DB.prepare(
		'SELECT daily_units, monthly_units, concurrency\n' +
			'FROM service_limit_overrides\n' +
			'WHERE account_id = ? AND service = ?'
	)
		.bind(accountID, service)
		.first();
	if (!override) return defaults;
	return {
		...defaults,
		dailyUnits: Number(override.daily_units),
		monthlyUnits: Number(override.monthly_units),
		concurrency: Number(override.concurrency)
	};
}

async function reserveServiceLease(env, accountID, service, limits) {
	const now = Date.now();
	const leaseID = crypto.randomUUID();
	await env.DB.prepare('DELETE FROM service_leases WHERE expires_at <= ?')
		.bind(now)
		.run();
	const result = await env.DB.prepare(
		'INSERT INTO service_leases (lease_id, account_id, service, expires_at, created_at)\n' +
			'SELECT ?, ?, ?, ?, ?\n' +
			'WHERE (\n' +
			'  SELECT COUNT(*) FROM service_leases\n' +
			'  WHERE account_id = ? AND service = ? AND expires_at > ?\n' +
			') < ?'
	)
		.bind(
			leaseID,
			accountID,
			service,
			now + limits.leaseMilliseconds,
			now,
			accountID,
			service,
			now,
			limits.concurrency
		)
		.run();
	return databaseChanges(result) === 1 ? leaseID : null;
}

async function releaseServiceLease(env, accountID, service, leaseID) {
	await env.DB.prepare(
		'DELETE FROM service_leases WHERE lease_id = ? AND account_id = ? AND service = ?'
	)
		.bind(leaseID, accountID, service)
		.run();
}

async function validServiceLease(env, accountID, service, leaseID) {
	return env.DB.prepare(
		'SELECT lease_id FROM service_leases\n' +
			'WHERE lease_id = ? AND account_id = ? AND service = ? AND expires_at > ?'
	)
		.bind(leaseID, accountID, service, Date.now())
		.first();
}

async function consumeServiceUnits(env, accountID, service, units, limits) {
	const now = new Date();
	const day = now.toISOString().slice(0, 10);
	const month = day.slice(0, 7);
	const usage = await env.DB.prepare(
		'SELECT\n' +
			'COALESCE(MAX(CASE WHEN usage_day = ? THEN units ELSE 0 END), 0) AS daily_units,\n' +
			'COALESCE(SUM(CASE WHEN substr(usage_day, 1, 7) = ? THEN units ELSE 0 END), 0) AS monthly_units\n' +
			'FROM service_usage\n' +
			'WHERE account_id = ? AND service = ?'
	)
		.bind(day, month, accountID, service)
		.first();
	const dailyUnits = Number(usage?.daily_units ?? 0);
	const monthlyUnits = Number(usage?.monthly_units ?? 0);
	if (
		dailyUnits + units > limits.dailyUnits ||
		monthlyUnits + units > limits.monthlyUnits
	) {
		return null;
	}
	// ponytail: the concurrency cap bounds a monthly counter race to one in-flight request.
	const result = await env.DB.prepare(
		'INSERT INTO service_usage (account_id, service, usage_day, units, updated_at)\n' +
			'VALUES (?, ?, ?, ?, ?)\n' +
			'ON CONFLICT(account_id, service, usage_day) DO UPDATE SET\n' +
			'units = service_usage.units + excluded.units,\n' +
			'updated_at = excluded.updated_at\n' +
			'WHERE service_usage.units + excluded.units <= ?'
	)
		.bind(accountID, service, day, units, Date.now(), limits.dailyUnits)
		.run();
	if (databaseChanges(result) !== 1) return null;
	return {
		dailyUnits: dailyUnits + units,
		monthlyUnits: monthlyUnits + units
	};
}

async function serviceUsage(request, env) {
	let value;
	try {
		value = await request.json();
	} catch {
		return json({ error: 'Invalid usage request.' }, { status: 400 });
	}
	const defaults = serviceUsageLimits[value?.service];
	if (!defaults || !['reserve', 'release'].includes(value?.action)) {
		return json({ error: 'Invalid usage request.' }, { status: 400 });
	}
	if (value.action === 'reserve' && !paidProcessingEnabled(env)) {
		return json({ error: 'Paid processing is temporarily paused.' }, { status: 503 });
	}
	const account = await serviceAccount(request, env);
	if (account.response) return account.response;
	const service = value.service;
	const accountID = account.customer.account_id;
	const leaseID =
		typeof value.leaseID === 'string' && /^[0-9a-f-]{36}$/i.test(value.leaseID)
			? value.leaseID
			: null;
	if (value.action === 'release') {
		if (!leaseID) return json({ error: 'Invalid usage lease.' }, { status: 400 });
		await releaseServiceLease(env, accountID, service, leaseID);
		return json({ released: true });
	}

	const limits = await accountServiceLimits(env, accountID, service);
	const units = Number(value.units ?? 0);
	if (!Number.isSafeInteger(units) || units < 0 || units > limits.dailyUnits) {
		return json({ error: 'Invalid usage amount.' }, { status: 400 });
	}
	const activeLease = leaseID
		? (await validServiceLease(env, accountID, service, leaseID))
			? leaseID
			: null
		: await reserveServiceLease(env, accountID, service, limits);
	if (!activeLease) return quotaResponse('Too many jobs are already running.');
	const usage =
		units === 0
			? { dailyUnits: 0, monthlyUnits: 0 }
			: await consumeServiceUnits(env, accountID, service, units, limits);
	if (!usage) {
		if (!leaseID) await releaseServiceLease(env, accountID, service, activeLease);
		return quotaResponse('This account has reached its processing allowance.');
	}
	return json({
		leaseID: activeLease,
		usage,
		limits: {
			dailyUnits: limits.dailyUnits,
			monthlyUnits: limits.monthlyUnits,
			concurrency: limits.concurrency
		}
	});
}

async function cleanServiceUsage(env) {
	const cutoff = new Date();
	cutoff.setUTCMonth(cutoff.getUTCMonth() - 2);
	await env.DB.batch([
		env.DB.prepare('DELETE FROM service_leases WHERE expires_at <= ?').bind(Date.now()),
		env.DB.prepare('DELETE FROM service_usage WHERE usage_day < ?').bind(
			cutoff.toISOString().slice(0, 10)
		)
	]);
}

export {
	cleanServiceUsage,
	processWithManagedAI,
	quotaResponse,
	scrapeWithFirecrawl,
	serviceUsage,
	serviceUsageLimits
};
