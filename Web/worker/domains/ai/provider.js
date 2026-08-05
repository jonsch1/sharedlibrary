const managedAIModel = 'openai/gpt-5.6-luna';

const managedAIJSONSchema = {
	name: 'briefly_processing',
	strict: true,
	schema: {
		type: 'object',
		additionalProperties: false,
		properties: {
			short_filename: { type: 'string' },
			summaries: {
				type: 'object',
				additionalProperties: false,
				properties: {
					detailed: { type: 'string' },
					concise: { type: 'string' }
				},
				required: ['detailed', 'concise']
			},
			topic_name: { type: 'string' }
		},
		required: ['short_filename', 'summaries', 'topic_name']
	}
};

function managedAIKey(env) {
	const apiKey = String(env.OPENROUTER_API_KEY || '').trim();
	return apiKey || null;
}

async function executeManagedAI({ apiKey, prompt, format, signal }) {
	const response = await fetch('https://openrouter.ai/api/v1/chat/completions', {
		method: 'POST',
		signal,
		headers: {
			Authorization: 'Bearer ' + apiKey,
			'Content-Type': 'application/json',
			'HTTP-Referer': 'https://www.readbriefly.fyi',
			'X-Title': 'Briefly'
		},
		body: JSON.stringify({
			model: managedAIModel,
			messages: [{ role: 'user', content: prompt }],
			max_tokens: format === 'json' ? 32_000 : 16_000,
			provider: {
				zdr: true,
				order: ['fireworks'],
				allow_fallbacks: true
			},
			...(format === 'json'
				? {
						response_format: {
							type: 'json_schema',
							json_schema: managedAIJSONSchema
						}
					}
				: {})
		})
	});
	if (!response.ok) {
		return {
			ok: false,
			status: response.status,
			error: 'Briefly AI via OpenRouter is temporarily unavailable.'
		};
	}

	let result;
	try {
		result = await response.json();
	} catch {
		return {
			ok: false,
			status: 502,
			error: 'Briefly AI via OpenRouter returned an invalid response.'
		};
	}
	const reportedCost = Number(result?.usage?.cost);
	const costMicros =
		Number.isFinite(reportedCost) && reportedCost >= 0
			? Math.ceil(reportedCost * 1_000_000)
			: null;
	return {
		ok: true,
		costMicros,
		output: result?.choices?.[0]?.message?.content
	};
}

export { executeManagedAI, managedAIKey };
