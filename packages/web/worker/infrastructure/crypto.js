function randomBase64URL(byteLength = 32) {
	const bytes = new Uint8Array(byteLength);
	crypto.getRandomValues(bytes);
	return bytesToBase64URL(bytes);
}

function bytesToBase64URL(bytes) {
	let binary = '';
	for (const byte of bytes) binary += String.fromCharCode(byte);
	return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

function base64URLToBytes(value) {
	const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
	const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, '=');
	const binary = atob(padded);
	return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

async function sha256Hex(value) {
	const input =
		typeof value === 'string'
			? new TextEncoder().encode(value)
			: value instanceof Uint8Array
				? value
				: new Uint8Array(value);
	const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', input));
	return [...digest].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

function pemBytes(value) {
	const encoded = value.replace(
		/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g,
		''
	);
	return Uint8Array.from(atob(encoded), (character) => character.charCodeAt(0));
}

function decodeJWTPart(value) {
	return JSON.parse(new TextDecoder().decode(base64URLToBytes(value)));
}

export {
	base64URLToBytes,
	bytesToBase64URL,
	decodeJWTPart,
	pemBytes,
	randomBase64URL,
	sha256Hex
};
