import { json, requestJSON, sameOriginResponse } from '../../infrastructure/http-security.js';
import { emailAddressPattern, normalizedEmail } from '../../infrastructure/input-validation.js';
import { accountRecord } from '../auth/account-operations.js';
import { administratorRequest } from './access.js';
import { serviceUsageLimits } from '../ai/usage.js';

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
			(usage.results ?? []).map((entry) => [entry.account_id + ':' + entry.service, entry])
		);
		const overrideByService = new Map(
			(overrides.results ?? []).map((entry) => [entry.account_id + ':' + entry.service, entry])
		);
		const leasesByService = new Map(
			(leases.results ?? []).map((entry) => [entry.account_id + ':' + entry.service, entry])
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
	const originError = sameOriginResponse(request);
	if (originError) return originError;
	const value = await requestJSON(request);
	if (value === undefined) {
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
			'\taccount_id, service, daily_units, monthly_units, concurrency, updated_at\n' +
			') VALUES (?, ?, ?, ?, ?, ?)\n' +
			'ON CONFLICT(account_id, service) DO UPDATE SET\n' +
			'\tdaily_units = excluded.daily_units,\n' +
			'\tmonthly_units = excluded.monthly_units,\n' +
			'\tconcurrency = excluded.concurrency,\n' +
			'\tupdated_at = excluded.updated_at'
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

export { adminUsage };
