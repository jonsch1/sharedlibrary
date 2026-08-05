function accountRecord(env, email) {
	return env.DB.prepare('SELECT account_id, user_email FROM accounts WHERE user_email = ?')
		.bind(email)
		.first();
}

async function ensureAccount(env, email) {
	const existing = await accountRecord(env, email);
	if (existing) return existing;
	const now = Date.now();
	await env.DB.prepare(
		'INSERT OR IGNORE INTO accounts (user_email, account_id, created_at, updated_at)\n' +
			'VALUES (?, ?, ?, ?)'
	)
		.bind(email, crypto.randomUUID(), now, now)
		.run();
	return accountRecord(env, email);
}

export { accountRecord, ensureAccount };
