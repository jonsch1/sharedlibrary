<script lang="ts">
	import LegalShell from '$lib/LegalShell.svelte';
	import { browser } from '$app/environment';

	function readConsent(): string | null {
		try { return browser ? localStorage.getItem('briefly_analytics_consent') : null; }
		catch { return null; }
	}
	let analyticsConsent = $state(readConsent());
	let storageError = $state('');

	function chooseAnalytics(value: 'yes' | 'no'): void {
		try {
			if (value === 'no') {
				for (const key of Object.keys(localStorage)) {
					if (key.startsWith('ph_')) localStorage.removeItem(key);
				}
			}
			localStorage.setItem('briefly_analytics_consent', value);
			analyticsConsent = value;
			location.reload();
		} catch {
			storageError = 'Browser storage is unavailable. Analytics remain disabled.';
		}
	}
</script>

<LegalShell
	active="cookies"
	title="Cookies & local storage"
	description="What Briefly stores on your device, why it is necessary, and how you can remove it."
>
	<section>
		<h2>1. The short version</h2>
		<p>
			Briefly does <strong>not</strong> use advertising cookies, tracking pixels, or device
		fingerprinting. It uses one first-party session cookie after authentication and local browser
			storage for theme and consent preferences. Anonymous product analytics
			are off unless you explicitly opt in below.
		</p>
		<div class="legal-callout">
			<p>
				<strong>Why there is no cookie banner:</strong> optional analytics start disabled.
				Briefly asks for consent here before enabling them; declining does not affect the
				service.
			</p>
		</div>
	</section>

	<section>
		<h2>2. Cookie used by Briefly</h2>
		<table>
			<thead>
				<tr>
					<th>Name</th>
					<th>Purpose</th>
					<th>Duration</th>
					<th>Access</th>
				</tr>
			</thead>
			<tbody>
				<tr>
					<td><code>shared_library_session</code></td>
					<td>Keeps authenticated native and support requests associated with the correct account. It is strictly necessary for hosted processing and sharing.</td>
					<td>Up to 90 days; deleted earlier when you sign out.</td>
					<td>First-party, Secure, HTTP-only, SameSite=Lax. Client-side JavaScript cannot read it.</td>
				</tr>
			</tbody>
		</table>
		<p>
			Apple may set its own cookies when you choose Sign in with Apple on a web support
			surface. Apple's notice governs those cookies; Briefly cannot read them.
		</p>
	</section>

	<section>
		<h2>3. Other storage on your device</h2>
		<table>
			<thead>
				<tr>
					<th>Technology</th>
					<th>Stored information</th>
					<th>Why</th>
					<th>Duration</th>
				</tr>
			</thead>
			<tbody>
				<tr>
					<td>Local storage</td>
					<td>Theme and interface preferences.</td>
					<td>Restores the interface choices you made.</td>
					<td>Until you change them or clear the site's data.</td>
				</tr>
				<tr>
					<td>Local storage, optional analytics</td>
					<td>Your analytics consent choice and, only after opt-in, PostHog's anonymous browser identifier and event queue.</td>
					<td>Remembers your choice and sends the limited product events described below. PostHog is configured not to use cookie persistence.</td>
					<td>Until you change the choice or clear the site's data.</td>
				</tr>
			</tbody>
		</table>
		<p>
			This local data normally stays on your device. Sync features request the
			necessary data through Briefly's service as described in the <a href="/privacy">Privacy Notice</a>.
		</p>
	</section>

	<section>
		<h2>4. Optional product analytics</h2>
		<p>
			If you opt in, Briefly sends a small set of manually named product events—such as starting
			sign-in, choosing a sync provider, or creating a share link—to PostHog's EU service.
			Briefly also reports client errors, but disables automatic interaction capture, page-view
			capture, and session recording. Events are not connected to your Briefly email.
		</p>
		<p>
				Current choice: <strong>{analyticsConsent === 'yes' ? 'enabled' : analyticsConsent === 'no' ? 'disabled' : 'not chosen (disabled)'}</strong>.
			</p>
			{#if storageError}<p role="status">{storageError}</p>{/if}
		<p>
			<button type="button" onclick={() => chooseAnalytics('yes')}>Allow anonymous analytics</button>
			<button type="button" onclick={() => chooseAnalytics('no')}>Disable analytics</button>
		</p>
	</section>

	<section>
		<h2>5. Your controls</h2>
		<ul>
			<li>Use <strong>Sign out</strong> in Briefly to delete the active session cookie from your browser and revoke that server session.</li>
			<li>Use <strong>Settings → Account → Delete Briefly account</strong> in the app to revoke every server session and delete the server-side account data described in the Privacy Policy.</li>
			<li>Use your browser's site-data settings to remove Briefly's cookie and local storage.</li>
			<li>Removing site data signs out web support surfaces and deletes browser preferences. It does not delete iCloud files or a public share.</li>
			<li>Manage private CloudKit data through your Apple account.</li>
			<li>Revoke each public share in the native app.</li>
		</ul>
		<p>
			Questions about device storage can be sent to
			<a href="mailto:hello@readbriefly.fyi">hello@readbriefly.fyi</a>.
		</p>
	</section>
</LegalShell>
