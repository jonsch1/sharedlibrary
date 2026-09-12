import posthog from 'posthog-js';
import { PUBLIC_POSTHOG_PROJECT_TOKEN, PUBLIC_POSTHOG_HOST } from '$env/static/public';
import type { HandleClientError } from '@sveltejs/kit';

function analyticsAllowed(): boolean {
	try {
		return location.pathname !== '/' &&
			!new URL(location.href).searchParams.has('shared') &&
			localStorage.getItem('briefly_analytics_consent') === 'yes';
	} catch {
		return false;
	}
}

function scrubShareURLs(value: unknown): unknown {
	if (typeof value === 'string') {
		return value.replace(/([?&]shared=|\/api\/public\/shares\/)[A-Za-z0-9_-]+/g, '$1[redacted]');
	}
	if (Array.isArray(value)) return value.map(scrubShareURLs);
	if (value && typeof value === 'object') {
		return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, scrubShareURLs(item)]));
	}
	return value;
}

export function startAnalytics(): void {
	if (!analyticsAllowed()) return;
	if (!PUBLIC_POSTHOG_PROJECT_TOKEN) {
		if (import.meta.env.DEV) console.warn('PostHog is not configured.');
		return;
	}

	posthog.init(PUBLIC_POSTHOG_PROJECT_TOKEN, {
		api_host: PUBLIC_POSTHOG_HOST,
		ui_host: 'https://eu.posthog.com',
		defaults: '2026-01-30',
		autocapture: false,
		capture_exceptions: true,
		capture_pageview: false,
		disable_session_recording: true,
		persistence: 'localStorage',
		mask_personal_data_properties: true,
		custom_personal_data_properties: ['shared'],
		before_send: (event) => analyticsAllowed() ? scrubShareURLs(event) as typeof event : null
	});
}

export function init(): void {
	startAnalytics();
}

export const handleError: HandleClientError = ({ error, status, message }) => {
	if (analyticsAllowed()) {
		posthog.captureException(error, { status });
	}
	return {
		message,
		status
	};
};
