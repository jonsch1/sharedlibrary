import { json, requestJSON, sameOriginResponse } from '../../infrastructure/http-security.js';
import { accountRecord, ensureAccount } from '../auth/account-operations.js';
import { authenticatedEmail } from '../auth/session.js';
import { paidAccessResponse } from '../auth/entitlements.js';
import {
	accountServiceLimits,
	consumeServiceUnits,
	paidProcessingEnabled,
	quotaResponse,
	releaseServiceLease,
	reserveServiceLease
} from './usage.js';

const firecrawlEndpoint = 'https://api.firecrawl.dev/v2/scrape';

async function scrapeWithFirecrawl(request, env) {
	const originError = sameOriginResponse(request);
	if (originError) return originError;
	const denied = await paidAccessResponse(request, env);
	if (denied) return denied;
	if (!paidProcessingEnabled(env)) {
		return json({ error: 'Web extraction is temporarily paused.' }, { status: 503 });
	}
	let rawURL;
	try {
		rawURL = (await requestJSON(request)).url;
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

export { scrapeWithFirecrawl };
