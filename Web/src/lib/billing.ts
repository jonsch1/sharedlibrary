export interface PricingTier {
	key: string;
	name: string;
	amount: number;
	currency: string;
	capacity: number | null;
	claimed: number;
	remaining: number | null;
	current: boolean;
}

export interface BillingSubscription {
	status: string;
	tierKey: string;
	tierName: string;
	amount: number;
	currency: string;
	cancelAtPeriodEnd: boolean;
	currentPeriodEnd: number | null;
}

export interface BillingStatus {
	configured: boolean;
	authenticated: boolean;
	entitled: boolean;
	subscription: BillingSubscription | null;
	tiers: PricingTier[];
}

async function billingError(response: Response, fallback: string): Promise<Error & { code?: string }> {
	let message = fallback;
	let code: string | undefined;
	try {
		const value = (await response.json()) as { error?: unknown; code?: unknown };
		if (typeof value.error === 'string') message = value.error;
		if (typeof value.code === 'string') code = value.code;
	} catch {
		// The response was not JSON.
	}
	const error = new Error(message) as Error & { code?: string };
	error.code = code;
	return error;
}

export async function loadBillingStatus(): Promise<BillingStatus> {
	const response = await fetch('/api/billing/status', {
		headers: { Accept: 'application/json' },
		cache: 'no-store'
	});
	if (!response.ok) {
		throw await billingError(response, 'Briefly Plus pricing could not be loaded.');
	}
	return (await response.json()) as BillingStatus;
}

export async function beginBrieflyPlusCheckout(): Promise<void> {
	const response = await fetch('/api/billing/checkout', {
		method: 'POST',
		headers: { Accept: 'application/json' }
	});
	if (!response.ok) {
		throw await billingError(response, 'Briefly Plus checkout could not be opened.');
	}
	const value = (await response.json()) as { url?: unknown };
	if (typeof value.url !== 'string') throw new Error('Stripe did not return a Checkout URL.');
	window.location.assign(value.url);
}

export async function openBillingPortal(): Promise<void> {
	const response = await fetch('/api/billing/portal', {
		method: 'POST',
		headers: { Accept: 'application/json' }
	});
	if (!response.ok) {
		throw await billingError(response, 'The billing portal could not be opened.');
	}
	const value = (await response.json()) as { url?: unknown };
	if (typeof value.url !== 'string') throw new Error('Stripe did not return a billing URL.');
	window.location.assign(value.url);
}

export function consumeBillingResult(): string | null {
	const url = new URL(window.location.href);
	const result = url.searchParams.get('billing');
	if (!result) return null;
	url.searchParams.delete('billing');
	window.history.replaceState({}, '', `${url.pathname}${url.search}${url.hash}`);
	return result;
}

export function formatMonthlyPrice(amount: number, currency = 'eur'): string {
	return new Intl.NumberFormat(undefined, {
		style: 'currency',
		currency: currency.toUpperCase(),
		minimumFractionDigits: 2
	}).format(amount / 100);
}
