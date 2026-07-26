<script lang="ts">
	import LegalShell from '$lib/LegalShell.svelte';
</script>

<LegalShell
	active="cookies"
	title="Cookies & local storage"
	description="What Briefly stores on your device, why it is necessary, and how you can remove it."
>
	<section>
		<h2>1. The short version</h2>
		<p>
			Briefly does <strong>not</strong> use advertising cookies, cross-site trackers, analytics
			cookies, tracking pixels, or device fingerprinting. It uses one first-party session cookie
			after sign-in and local browser storage for the offline library, narration cache, and
			preferences you choose.
		</p>
		<div class="legal-callout">
			<p>
				<strong>Why there is no cookie banner:</strong> Briefly currently stores only the
				session and local functionality needed to provide the service you request. It does not
				set optional tracking or advertising technology. If that changes, we will update this
				notice and request consent before non-essential storage is used where required.
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
					<td>Keeps you signed in and associates requests with the correct account. It is strictly necessary for account, sync, sharing, and billing features.</td>
					<td>Up to 90 days; deleted earlier when you sign out.</td>
					<td>First-party, Secure, HTTP-only, SameSite=Lax. Client-side JavaScript cannot read it.</td>
				</tr>
			</tbody>
		</table>
		<p>
			Apple, Google, Stripe, or GitHub may set their own cookies when you choose to visit
			their domains for sign-in, iCloud or Drive connection, AI voice top-up, billing management, or
			downloads. Their notices govern those cookies; Briefly cannot read them.
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
					<td>IndexedDB</td>
					<td>Your library index and mirrored Markdown documents.</td>
					<td>Opens your last complete library quickly and keeps reading available offline.</td>
					<td>Until replaced during sync or you clear the site's data.</td>
				</tr>
				<tr>
					<td>Cache API</td>
					<td>Application files and generated narration audio.</td>
					<td>Makes the web app work offline and avoids regenerating or redownloading narration.</td>
					<td>App files rotate with releases; audio remains until cleared or the browser evicts it.</td>
				</tr>
				<tr>
					<td>Local storage</td>
					<td>Selected topic and your preferred AI voice quality and narrator.</td>
					<td>Restores the interface choices you made.</td>
					<td>Until you change them or clear the site's data.</td>
				</tr>
			</tbody>
		</table>
		<p>
			This local data normally stays on your device. Sync and narration features request the
			necessary data through Briefly's service as described in the <a href="/privacy">Privacy Notice</a>.
		</p>
	</section>

	<section>
		<h2>4. Your controls</h2>
		<ul>
			<li>Use <strong>Sign out</strong> in Briefly to delete the active session cookie from your browser and revoke that server session.</li>
			<li>Use your browser's site-data settings to remove Briefly's cookie, IndexedDB, local storage, service worker, and caches.</li>
			<li>Removing site data signs you out and deletes the offline web copy and preferences on that device. It does not delete files in iCloud or Google Drive, an active subscription, or a public share.</li>
			<li>Disconnect Google Drive from Settings to delete the stored Google provider credentials.</li>
			<li>Stop iCloud sync from Settings to clear the selected-provider preference. Manage private CloudKit data through your Apple account.</li>
			<li>Revoke each public share in the app, and use Stripe's billing portal to manage or cancel Briefly Plus.</li>
		</ul>
		<p>
			Questions about device storage can be sent to
			<a href="mailto:hello@readbriefly.fyi">hello@readbriefly.fyi</a>.
		</p>
	</section>
</LegalShell>
