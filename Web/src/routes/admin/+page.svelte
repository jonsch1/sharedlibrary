<script lang="ts">
	import { onMount } from 'svelte';

	type Access = { email: string; createdAt: number };
	type Limits = { dailyUnits: number; monthlyUnits: number; concurrency: number };
	type Service = {
		service: string;
		usage: { dailyUnits: number; monthlyUnits: number; activeLeases: number };
		limits: Limits;
		custom: boolean;
	};
	type Account = { email: string; services: Service[] };

	const serviceNames: Record<string, string> = {
		transcription: 'Transcription',
		voice: 'AI voice',
		firecrawl: 'Web extraction',
		media: 'Media upload'
	};
	const serviceUnits: Record<string, string> = {
		transcription: 'seconds',
		voice: 'characters',
		firecrawl: 'credits',
		media: 'bytes'
	};

	let emails = $state<Access[]>([]);
	let accounts = $state<Account[]>([]);
	let email = $state('');
	let loading = $state(true);
	let busy = $state('');
	let error = $state('');
	let denied = $state<'signed-out' | 'forbidden' | null>(null);

	onMount(() => void load());

	async function accessRequest(
		method: 'GET' | 'POST' | 'DELETE',
		value?: string
	): Promise<Response> {
		return fetch('/api/admin/complimentary-access', {
			method,
			headers: value ? { 'Content-Type': 'application/json' } : undefined,
			body: value ? JSON.stringify({ email: value }) : undefined,
			cache: 'no-store'
		});
	}

	async function usageRequest(
		method: 'GET' | 'PUT' | 'DELETE',
		value?: object
	): Promise<Response> {
		return fetch('/api/admin/usage', {
			method,
			headers: value ? { 'Content-Type': 'application/json' } : undefined,
			body: value ? JSON.stringify(value) : undefined,
			cache: 'no-store'
		});
	}

	async function load(): Promise<void> {
		const [accessResponse, usageResponse] = await Promise.all([
			accessRequest('GET'),
			usageRequest('GET')
		]);
		if (accessResponse.status === 401 || usageResponse.status === 401) denied = 'signed-out';
		else if (accessResponse.status === 403 || usageResponse.status === 403) denied = 'forbidden';
		else if (accessResponse.ok && usageResponse.ok) {
			emails = ((await accessResponse.json()) as { emails: Access[] }).emails;
			accounts = ((await usageResponse.json()) as { accounts: Account[] }).accounts;
		} else error = 'The admin dashboard could not be loaded.';
		loading = false;
	}

	async function add(event: SubmitEvent): Promise<void> {
		event.preventDefault();
		const value = email.trim().toLowerCase();
		if (!value || busy) return;
		busy = value;
		error = '';
		const response = await accessRequest('POST', value);
		const result = (await response.json()) as { error?: string; createdAt?: number };
		if (!response.ok) error = result.error ?? 'Access could not be added.';
		else {
			emails = [
				{ email: value, createdAt: result.createdAt ?? Date.now() },
				...emails.filter((entry) => entry.email !== value)
			];
			email = '';
		}
		busy = '';
	}

	async function remove(value: string): Promise<void> {
		if (busy) return;
		busy = value;
		error = '';
		const response = await accessRequest('DELETE', value);
		const result = (await response.json()) as { error?: string };
		if (!response.ok) error = result.error ?? 'Access could not be removed.';
		else emails = emails.filter((entry) => entry.email !== value);
		busy = '';
	}

	async function saveLimits(account: Account, service: Service): Promise<void> {
		const key = `${account.email}:${service.service}`;
		if (busy) return;
		busy = key;
		error = '';
		const response = await usageRequest('PUT', {
			email: account.email,
			service: service.service,
			limits: service.limits
		});
		const result = (await response.json()) as { error?: string; limits: Limits; custom: boolean };
		if (!response.ok) error = result.error ?? 'Usage limits could not be saved.';
		else {
			service.limits = result.limits;
			service.custom = result.custom;
		}
		busy = '';
	}

	async function resetLimits(account: Account, service: Service): Promise<void> {
		const key = `${account.email}:${service.service}`;
		if (busy) return;
		busy = key;
		error = '';
		const response = await usageRequest('DELETE', {
			email: account.email,
			service: service.service
		});
		const result = (await response.json()) as { error?: string; limits: Limits; custom: boolean };
		if (!response.ok) error = result.error ?? 'Usage limits could not be reset.';
		else {
			service.limits = result.limits;
			service.custom = result.custom;
		}
		busy = '';
	}

	function formatUnits(service: string, units: number): string {
		if (service === 'media') {
			const [divisor, unit] =
				units >= 1_000_000_000
					? [1_000_000_000, 'GB']
					: units >= 1_000_000
						? [1_000_000, 'MB']
						: units >= 1_000
							? [1_000, 'KB']
							: [1, 'B'];
			return `${(units / divisor).toLocaleString(undefined, { maximumFractionDigits: 1 })} ${unit}`;
		}
		if (service === 'transcription') {
			if (units < 3600) return `${units.toLocaleString()} s`;
			return `${(units / 3600).toLocaleString(undefined, { maximumFractionDigits: 1 })} h`;
		}
		return units.toLocaleString();
	}
</script>

<svelte:head>
	<title>Admin — Briefly</title>
	<meta name="description" content="Manage Briefly accounts, usage, and limits." />
</svelte:head>

<main>
	<nav><a href="/account">← Account</a></nav>
	<header>
		<p class="eyebrow">Briefly admin</p>
		<h1>Admin dashboard</h1>
	</header>
	{#if loading}
		<p class="status">Loading…</p>
	{:else if denied === 'signed-out'}
		<section>
			<p>Sign in with the administrator account to continue.</p>
			<a class="button" href="/api/auth/google/start?return_to=%2Fadmin">Continue with Google</a>
		</section>
	{:else if denied === 'forbidden'}
		<section><p>This account is not an administrator.</p></section>
	{:else}
		<div class="dashboard">
			{#if error}<p class="error" role="alert">{error}</p>{/if}
			<section class="usage-panel">
				<h2>User usage &amp; limits</h2>
				<p class="intro">Today and month-to-date usage use UTC. Changes apply immediately.</p>
				<div class="accounts">
					{#each accounts as account, accountIndex (account.email)}
						<details open>
							<summary>{account.email}</summary>
							<div class="table-wrap">
								<table>
									<thead>
										<tr>
											<th>Service</th>
											<th>Today</th>
											<th>This month</th>
											<th>Active</th>
											<th>Daily limit</th>
											<th>Monthly limit</th>
											<th>Concurrent</th>
											<th><span class="visually-hidden">Actions</span></th>
										</tr>
									</thead>
									<tbody>
										{#each account.services as service, serviceIndex (service.service)}
											<tr>
												<th scope="row">
													{serviceNames[service.service] ?? service.service}
													<small>{serviceUnits[service.service] ?? 'units'}</small>
												</th>
												<td>{formatUnits(service.service, service.usage.dailyUnits)}</td>
												<td>{formatUnits(service.service, service.usage.monthlyUnits)}</td>
												<td>{service.usage.activeLeases} / {service.limits.concurrency}</td>
												<td>
													<label class="visually-hidden" for={`daily-${accountIndex}-${serviceIndex}`}>
														Daily {serviceUnits[service.service]} limit for {account.email}
													</label>
													<input
														id={`daily-${accountIndex}-${serviceIndex}`}
														type="number"
														min="0"
														step="1"
														bind:value={service.limits.dailyUnits}
													/>
												</td>
												<td>
													<label class="visually-hidden" for={`monthly-${accountIndex}-${serviceIndex}`}>
														Monthly {serviceUnits[service.service]} limit for {account.email}
													</label>
													<input
														id={`monthly-${accountIndex}-${serviceIndex}`}
														type="number"
														min="0"
														step="1"
														bind:value={service.limits.monthlyUnits}
													/>
												</td>
												<td>
													<label class="visually-hidden" for={`concurrency-${accountIndex}-${serviceIndex}`}>
														Concurrent jobs limit for {account.email}
													</label>
													<input
														id={`concurrency-${accountIndex}-${serviceIndex}`}
														class="concurrency"
														type="number"
														min="0"
														step="1"
														bind:value={service.limits.concurrency}
													/>
												</td>
												<td class="actions">
													<button
														type="button"
														onclick={() => saveLimits(account, service)}
														disabled={Boolean(busy)}
													>
														{busy === `${account.email}:${service.service}` ? 'Saving…' : 'Save'}
													</button>
													{#if service.custom}
														<button
															class="secondary"
															type="button"
															onclick={() => resetLimits(account, service)}
															disabled={Boolean(busy)}
														>Reset</button>
													{/if}
												</td>
											</tr>
										{/each}
									</tbody>
								</table>
							</div>
						</details>
					{:else}
						<p class="empty">No user accounts yet.</p>
					{/each}
				</div>
			</section>

			<section class="access-panel">
				<h2>Complimentary access</h2>
				<form class="access-form" onsubmit={add}>
					<label for="email">Email address</label>
					<div>
						<input id="email" type="email" bind:value={email} placeholder="person@example.com" required />
						<button type="submit" disabled={Boolean(busy)}>Grant access</button>
					</div>
				</form>
				<ul>
					{#each emails as entry (entry.email)}
						<li>
							<span>
								<strong>{entry.email}</strong>
								<small>Added {new Date(entry.createdAt).toLocaleDateString()}</small>
							</span>
							<button class="remove" onclick={() => remove(entry.email)} disabled={Boolean(busy)}>
								{busy === entry.email ? 'Removing…' : 'Remove'}
							</button>
						</li>
					{:else}
						<li class="empty">No complimentary accounts yet.</li>
					{/each}
				</ul>
			</section>
		</div>
	{/if}
</main>

<style>
	:global(body) {
		overflow: auto;
		background: #eeebdf;
	}

	main {
		min-height: 100dvh;
		padding: 24px;
		background:
			radial-gradient(circle at 15% 0%, rgb(50 99 224 / 12%), transparent 28%),
			linear-gradient(145deg, #f4f1e7, #e5e1d5);
		color: #151512;
	}

	nav,
	header,
	.dashboard,
	main > section,
	.status {
		width: min(1180px, 100%);
		margin: 0 auto;
	}

	nav a {
		color: #4b4a44;
		font-size: 13px;
	}

	header {
		margin-top: 64px;
	}

	.dashboard {
		display: grid;
		gap: 24px;
	}

	section {
		padding: clamp(24px, 5vw, 48px);
		border: 1px solid rgb(21 21 18 / 12%);
		border-radius: 28px;
		background: rgb(255 255 255 / 62%);
		box-shadow: 0 24px 70px rgb(21 21 18 / 8%);
	}

	.eyebrow {
		margin: 0;
		color: #5d5b53;
		font-size: 10px;
		font-weight: 780;
		letter-spacing: 0.13em;
		text-transform: uppercase;
	}

	h1 {
		margin: 8px 0 36px;
		font-family: "Iowan Old Style", Charter, Georgia, serif;
		font-size: clamp(38px, 7vw, 64px);
		letter-spacing: -0.055em;
		line-height: 0.96;
	}

	h2 {
		margin: 0;
		font-family: "Iowan Old Style", Charter, Georgia, serif;
		font-size: clamp(26px, 4vw, 36px);
		letter-spacing: -0.035em;
	}

	.intro {
		margin: 8px 0 24px;
		color: #5d5b53;
		font-size: 13px;
	}

	.accounts {
		display: grid;
		gap: 12px;
	}

	details {
		border: 1px solid rgb(21 21 18 / 10%);
		border-radius: 16px;
		background: rgb(255 255 255 / 48%);
		overflow: hidden;
	}

	summary {
		padding: 16px;
		font-weight: 750;
		cursor: pointer;
	}

	.table-wrap {
		overflow-x: auto;
		border-top: 1px solid rgb(21 21 18 / 8%);
	}

	table {
		width: 100%;
		min-width: 1020px;
		border-collapse: collapse;
		font-size: 12px;
	}

	th,
	td {
		padding: 10px 8px;
		border-bottom: 1px solid rgb(21 21 18 / 7%);
		text-align: left;
		white-space: nowrap;
	}

	tbody tr:last-child th,
	tbody tr:last-child td {
		border-bottom: 0;
	}

	thead th {
		color: #77746a;
		font-size: 10px;
		letter-spacing: 0.05em;
		text-transform: uppercase;
	}

	tbody th {
		padding-left: 16px;
	}

	tbody th small {
		display: block;
		margin-top: 2px;
		color: #77746a;
		font-weight: 400;
	}

	.access-form {
		margin-top: 24px;
	}

	.access-form > label {
		display: block;
		margin-bottom: 8px;
		font-size: 12px;
		font-weight: 700;
	}

	.access-form > div {
		display: flex;
		gap: 10px;
	}

	.access-form input {
		min-width: 0;
		flex: 1;
		padding: 13px 16px;
		border: 1px solid rgb(21 21 18 / 18%);
		border-radius: 999px;
		background: white;
		font: inherit;
	}

	td input {
		width: 120px;
		padding: 9px;
		border: 1px solid rgb(21 21 18 / 18%);
		border-radius: 8px;
		background: white;
		font: inherit;
	}

	td input.concurrency {
		width: 72px;
	}

	button,
	.button {
		display: inline-flex;
		min-height: 44px;
		align-items: center;
		justify-content: center;
		padding: 0 18px;
		border: 0;
		border-radius: 999px;
		background: #151512;
		color: white;
		font: inherit;
		font-size: 12px;
		font-weight: 750;
		cursor: pointer;
	}

	button:disabled {
		cursor: wait;
		opacity: 0.55;
	}

	.actions {
		display: flex;
		gap: 4px;
	}

	.actions button {
		min-height: 34px;
		padding: 0 12px;
	}

	button.secondary {
		background: transparent;
		color: #5d5b53;
	}

	.error {
		margin: 0;
		color: #a52a2a;
		font-size: 13px;
	}

	.access-panel ul {
		display: grid;
		gap: 8px;
		margin: 28px 0 0;
		padding: 0;
		list-style: none;
	}

	.access-panel li {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 16px;
		padding: 14px 16px;
		border: 1px solid rgb(21 21 18 / 10%);
		border-radius: 16px;
		background: rgb(255 255 255 / 48%);
	}

	.access-panel li span {
		display: grid;
		gap: 4px;
		min-width: 0;
	}

	.access-panel li strong {
		overflow-wrap: anywhere;
	}

	.access-panel li small {
		color: #77746a;
	}

	.remove {
		min-height: 36px;
		background: transparent;
		color: #a52a2a;
	}

	.empty {
		color: #77746a;
		text-align: center;
	}

	.access-panel .empty {
		justify-content: center;
	}

	.visually-hidden {
		position: absolute;
		width: 1px;
		height: 1px;
		padding: 0;
		margin: -1px;
		overflow: hidden;
		clip: rect(0, 0, 0, 0);
		white-space: nowrap;
		border: 0;
	}

	@media (max-width: 560px) {
		.access-form > div {
			align-items: stretch;
			flex-direction: column;
		}

		header {
			margin-top: 36px;
		}

		section {
			padding: 24px 16px;
		}
	}
</style>
