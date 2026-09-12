import { databaseChanges } from '../../infrastructure/database.js';

const managedAIMonthlyAllowanceMicros = 5_000_000;
const managedAIReservationMicros = 500_000;
const managedAIReservationStaleMilliseconds = 20 * 60 * 1000;

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

export {
	managedAIMonthlyAllowanceMicros,
	managedAIReservationMicros,
	releaseManagedAIUsage,
	reserveManagedAIUsage,
	settleManagedAIUsage
};
