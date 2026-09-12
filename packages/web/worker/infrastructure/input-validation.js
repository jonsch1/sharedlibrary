const uuidPattern =
	/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const emailAddressPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function normalizedEmail(email) {
	return String(email || '').trim().toLowerCase();
}

export { emailAddressPattern, normalizedEmail, uuidPattern };
