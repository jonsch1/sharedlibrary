import { accountStatus } from '../domains/auth/account-status.js';
import { startAppleLogin } from '../domains/auth/apple.js';
import { finishAppleLogin as finishAppleLoginHandler } from '../domains/auth/apple.js';
import { finishNativeAppleLogin as finishNativeAppleLoginHandler } from '../domains/auth/apple.js';
import { signInForAppReview } from '../domains/auth/review-access.js';
import { signOut } from '../domains/auth/session.js';
import { deleteAccount } from '../domains/auth/deletion.js';
import { adminServiceAccess } from '../domains/admin/access.js';
import { adminContentReports } from '../domains/admin/content-reports.js';
import { adminUsage } from '../domains/admin/usage.js';
import { createFeedback, feedbackBoard, setFeedbackUpvote } from '../domains/feedback/feedback.js';
import { processWithManagedAI } from '../domains/ai/managed.js';
import { scrapeWithFirecrawl } from '../domains/ai/extraction.js';
import { cleanServiceUsage, serviceUsage } from '../domains/ai/usage.js';
import { ownerShareLinkStatus, publishShareLink, revokeShareLink } from '../domains/sharing/owner.js';
import { publicContentReport, publicShareDocument } from '../domains/sharing/public.js';
import { json } from '../infrastructure/http-security.js';

const routeWorker = {
	async fetch(request, env, context) {
		const url = new URL(request.url);
		if (url.hostname === 'readbriefly.fyi') {
			url.hostname = 'www.readbriefly.fyi';
			return Response.redirect(url.toString(), 308);
		}
		const publicReport = url.pathname.match(
			/^\/api\/public\/shares\/([A-Za-z0-9_-]{32})\/reports$/
		);
		if (publicReport && request.method === 'POST') {
			return publicContentReport(request, env, publicReport[1]);
		}
		const publicShare = url.pathname.match(
			/^\/api\/public\/shares\/([A-Za-z0-9_-]{32})$/
		);
		if (publicShare && request.method === 'GET') {
			return publicShareDocument(request, env, publicShare[1]);
		}
		if (url.pathname === '/api/auth/status' && request.method === 'GET') {
			return accountStatus(request, env);
		}
		if (url.pathname === '/api/auth/apple/start' && request.method === 'GET') {
			return startAppleLogin(request, env);
		}
		if (url.pathname === '/api/auth/apple/callback' && request.method === 'POST') {
			return finishAppleLoginHandler(request, env);
		}
		if (url.pathname === '/api/auth/apple/native' && request.method === 'POST') {
			return finishNativeAppleLoginHandler(request, env);
		}
		if (url.pathname === '/api/auth/review' && request.method === 'POST') {
			return signInForAppReview(request, env);
		}
		if (url.pathname === '/api/auth/logout' && request.method === 'POST') {
			return signOut(request, env);
		}
		if (url.pathname === '/api/auth/account' && request.method === 'DELETE') {
			return deleteAccount(request, env);
		}
		if (
			url.pathname === '/api/admin/service-access' &&
			['GET', 'POST', 'DELETE'].includes(request.method)
		) {
			return adminServiceAccess(request, env);
		}
		if (
			url.pathname === '/api/admin/usage' &&
			['GET', 'PUT', 'DELETE'].includes(request.method)
		) {
			return adminUsage(request, env);
		}
		if (
			url.pathname === '/api/admin/content-reports' &&
			['GET', 'PATCH'].includes(request.method)
		) {
			return adminContentReports(request, env, context);
		}
		if (url.pathname === '/api/feedback' && request.method === 'GET') {
			return feedbackBoard(request, env);
		}
		if (url.pathname === '/api/feedback' && request.method === 'POST') {
			return createFeedback(request, env);
		}
		const feedbackUpvote = url.pathname.match(
			/^\/api\/feedback\/([0-9a-f-]{36})\/upvote$/
		);
		if (feedbackUpvote && request.method === 'PUT') {
			return setFeedbackUpvote(request, env, feedbackUpvote[1]);
		}
		if (url.pathname === '/api/usage' && request.method === 'POST') {
			return serviceUsage(request, env);
		}
		if (url.pathname === '/api/extraction/firecrawl' && request.method === 'POST') {
			return scrapeWithFirecrawl(request, env);
		}
		if (url.pathname === '/api/ai/process' && request.method === 'POST') {
			return processWithManagedAI(request, env);
		}
		if (url.pathname === '/api/share-links' && request.method === 'GET') {
			return ownerShareLinkStatus(request, env);
		}
		if (url.pathname === '/api/share-links' && request.method === 'POST') {
			return publishShareLink(request, env, context);
		}
		const ownerShare = url.pathname.match(/^\/api\/share-links\/([A-Za-z0-9_-]{32})$/);
		if (ownerShare && request.method === 'DELETE') {
			return revokeShareLink(request, env, ownerShare[1], context);
		}
		if (url.pathname.startsWith('/api/')) {
			return json({ error: 'Not found.' }, { status: 404 });
		}

		return env.ASSETS.fetch(request);
	},
	async scheduled(_controller, env, context) {
		context.waitUntil(cleanServiceUsage(env));
	}
};

export { routeWorker };
