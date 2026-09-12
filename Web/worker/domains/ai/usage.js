import { databaseChanges } from '../../infrastructure/database.js';
import { json, requestJSON } from '../../infrastructure/http-security.js';
import { authenticatedEmail } from '../auth/session.js';
import { ensureAccount } from '../auth/account-operations.js';
import { hostedServiceAccessResponse } from '../auth/service-access.js';

const serviceUsageLimits = {
	transcription: {
		dailyUnits: 24 * 60 * 60,
		monthlyUnits: 200 * 60 * 60,
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

function hostedProcessingEnabled(env) {
	return String(env.HOSTED_PROCESSING_ENABLED ?? 'true').toLowerCase() !== 'false';
}

function quotaResponse(message) {
	return json(
		{ error: message, code: 'usage_limit_reached' },
		{ status: 429, headers: { 'Retry-After': '3600' } }
	);
}

async function serviceAccount(request, env) {
	const response = await hostedServiceAccessResponse(request, env);
	if (response) return { response };
	const email = await authenticatedEmail(request, env);
	return { email, customer: await ensureAccount(env, email) };
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
	// The concurrency cap bounds this monthly counter race to one in-flight request.
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
	const value = await requestJSON(request);
	if (value === undefined) {
		return json({ error: 'Invalid usage request.' }, { status: 400 });
	}
	const defaults = serviceUsageLimits[value?.service];
	if (!defaults || !['reserve', 'release'].includes(value?.action)) {
		return json({ error: 'Invalid usage request.' }, { status: 400 });
	}
	if (value.action === 'reserve' && !hostedProcessingEnabled(env)) {
		return json({ error: 'Hosted processing is temporarily paused.' }, { status: 503 });
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
	accountServiceLimits,
	cleanServiceUsage,
	consumeServiceUnits,
	hostedProcessingEnabled,
	quotaResponse,
	releaseServiceLease,
	reserveServiceLease,
	serviceUsage,
	serviceUsageLimits,
	validServiceLease
};
