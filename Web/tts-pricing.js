export const ttsTopUpAmounts = [500, 1000, 2000];

export const ttsModels = [
	{
		model: 'hexgrad/kokoro-82m',
		quality: 'Low',
		name: 'Kokoro 82M',
		hoursPerEuro: 10,
		retailCentsPerMillionCharacters: 75,
		description: 'Fast, clear narration at the lowest cost.',
		voices: [
			'af_heart', 'af_alloy', 'af_aoede', 'af_bella', 'af_jessica', 'af_kore',
			'af_nicole', 'af_nova', 'af_river', 'af_sarah', 'af_sky', 'am_adam',
			'am_echo', 'am_eric', 'am_fenrir', 'am_liam', 'am_michael', 'am_onyx',
			'am_puck', 'am_santa', 'bf_alice', 'bf_emma', 'bf_isabella', 'bf_lily',
			'bm_daniel', 'bm_fable', 'bm_george', 'bm_lewis', 'ef_dora', 'em_alex',
			'em_santa', 'ff_siwis', 'hf_alpha', 'hf_beta', 'hm_omega', 'hm_psi',
			'if_sara', 'im_nicola', 'jf_alpha', 'jf_gongitsune', 'jf_nezumi',
			'jf_tebukuro', 'jm_kumo', 'pf_dora', 'pm_alex', 'pm_santa', 'zf_xiaobei',
			'zf_xiaoni', 'zf_xiaoxiao', 'zf_xiaoyi', 'zm_yunjian', 'zm_yunxi',
			'zm_yunxia', 'zm_yunyang'
		]
	},
	{
		model: 'canopylabs/orpheus-3b-0.1-ft',
		quality: 'Medium',
		name: 'Orpheus 3B',
		hoursPerEuro: 2,
		retailCentsPerMillionCharacters: 840,
		description: 'More expressive delivery at a mid-range price.',
		voices: ['tara', 'leah', 'jess', 'leo', 'dan', 'mia', 'zac']
	},
	{
		model: 'x-ai/grok-voice-tts-1.0',
		quality: 'High',
		name: 'Grok Voice',
		hoursPerEuro: 1,
		retailCentsPerMillionCharacters: 1800,
		description: 'The most natural, polished narration.',
		voices: ['eve', 'ara', 'rex', 'sal', 'leo']
	}
];

/**
 * @param {string} model
 * @param {number} characterCount
 */
export function ttsChargeMicros(model, characterCount) {
	const option = ttsModels.find((candidate) => candidate.model === model);
	if (!option || !Number.isSafeInteger(characterCount) || characterCount <= 0) return null;
	// One microcent per character equals one cent per million characters.
	return option.retailCentsPerMillionCharacters * characterCount;
}
