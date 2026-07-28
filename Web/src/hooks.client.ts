import posthog from 'posthog-js';
import { PUBLIC_POSTHOG_PROJECT_TOKEN, PUBLIC_POSTHOG_HOST } from '$env/static/public';
import type { HandleClientError } from '@sveltejs/kit';

export function startAnalytics(): void {
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
		persistence: 'localStorage'
	});
}

export function init(): void {
	if (localStorage.getItem('briefly_analytics_consent') === 'yes') {
		startAnalytics();
	}
}

export const handleError: HandleClientError = ({ error, status, message }) => {
	if (localStorage.getItem('briefly_analytics_consent') === 'yes') {
		posthog.captureException(error, { status });
	}
	return {
		message,
		status
	};
};
