import { json, requireSameOrigin } from '../../infrastructure/http-security.js';
import { accountRecord, ensureAccount } from '../auth/account-operations.js';
import { authenticatedEmail } from '../auth/session.js';
import {
	activeAppStoreSubscription,
	hasComplimentaryPlusAccess
} from '../auth/entitlements.js';
import {
	managedAIMonthlyAllowanceMicros,
	releaseManagedAIUsage,
	reserveManagedAIUsage,
	settleManagedAIUsage
} from './managed-usage.js';
import { executeManagedAI, managedAIKey } from './provider.js';

const managedAIUpstreamTimeoutMilliseconds = 15 * 60 * 1000;
const maximumManagedAIPromptLength = 600_000;

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
		const provider = await executeManagedAI({
			apiKey,
			prompt,
			format,
			signal: upstreamController.signal
		});
		if (!provider.ok) return json({ error: provider.error }, { status: provider.status });
		const costMicros = provider.costMicros ?? reservation.reservationMicros;
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
		if (typeof provider.output !== 'string' || !provider.output.trim()) {
			return json(
				{ error: 'Briefly AI via OpenRouter returned no output.' },
				{ status: 502 }
			);
		}
		return json({ output: provider.output, remainingMicros });
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

export { processWithManagedAI };
