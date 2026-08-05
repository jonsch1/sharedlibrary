import { json, secureResponse } from './http-security.js';
import { routeWorker } from './router.js';

const worker = {
	async fetch(request, env, context) {
		const requestID = crypto.randomUUID();
		try {
			return secureResponse(
				await routeWorker.fetch(request, env, context),
				requestID
			);
		} catch (error) {
			console.error(
				JSON.stringify({
					level: 'error',
					requestID,
					method: request.method,
					path: new URL(request.url).pathname,
					message: error instanceof Error ? error.message : String(error)
				})
			);
			return secureResponse(
				json(
					{ error: 'Briefly could not complete this request.', requestID },
					{ status: 500 }
				),
				requestID
			);
		}
	},
	scheduled(controller, env, context) {
		return routeWorker.scheduled(controller, env, context);
	}
};

export { serviceUsageLimits } from './ai-service-usage.js';
export { validAppStoreTransaction } from './billing.js';
export default worker;
