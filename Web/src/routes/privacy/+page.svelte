<script lang="ts">
	import LegalShell from '$lib/LegalShell.svelte';
</script>

<LegalShell
	active="privacy"
	title="Privacy notice"
	description="How Briefly processes personal data, the choices you control, and your rights under the GDPR."
>
	<section>
		<h2>1. Who is responsible</h2>
		<p>
			Briefly is operated by <strong>Jonathan Schaul</strong>, Lutherstr. 36, 69120 Heidelberg,
			Germany. Briefly is the data controller for the server-side processing described in this
			notice. Full provider details are available in the <a href="/imprint">Imprint</a>.
		</p>
		<p>
			For any privacy question or request, email
			<a href="mailto:hello@readbriefly.fyi">hello@readbriefly.fyi</a>. Briefly has not appointed
			a data protection officer because its current processing does not require one.
		</p>
		<div class="legal-callout">
			<p>
				<strong>Local-first by default.</strong> The desktop app keeps your workspace on
				your device. Briefly does not receive that library unless you choose a connected
				feature such as cloud synchronization or a public share link. Private
				iCloud sync passes directly between your device and Apple.
			</p>
		</div>
	</section>

	<section>
		<h2>2. What we process and why</h2>
		<table>
			<thead>
				<tr>
					<th>Activity</th>
					<th>Personal data</th>
					<th>Purpose</th>
					<th>Legal basis</th>
				</tr>
			</thead>
			<tbody>
				<tr>
					<td>Website delivery</td>
					<td>IP address, request details, device/browser information, and security events.</td>
					<td>Deliver and secure the site, prevent abuse, and diagnose failures.</td>
					<td>Legitimate interests in a secure and reliable service.</td>
				</tr>
				<tr>
					<td>Apple or Google sign-in</td>
					<td>Email address, provider account identifier, a hashed session token, session dates, and short-lived OAuth state.</td>
					<td>Authenticate you and keep the correct account connected.</td>
					<td>Performance of our contract with you.</td>
				</tr>
				<tr>
					<td>iCloud sync</td>
					<td>Your selected-provider preference. Apple processes the private CloudKit records and documents exchanged directly with your device.</td>
					<td>Synchronize the Briefly files you choose without sending private iCloud content through Briefly's application server.</td>
					<td>Performance of our contract; you choose whether to connect iCloud.</td>
				</tr>
				<tr>
					<td>Google Drive sync</td>
					<td>Encrypted Google access/refresh tokens, connection dates, folder ID, library index, and documents passing through the service.</td>
					<td>Read and update the Briefly files you ask us to synchronize. Private file content is proxied in memory and is not retained in Briefly's application database.</td>
					<td>Performance of our contract; you choose whether to connect Drive.</td>
				</tr>
				<tr>
					<td>Public share links</td>
					<td>Your account email, document text and metadata, source URL, share token, and timestamps.</td>
					<td>Publish the specific document you deliberately select at a forwardable public link.</td>
					<td>Performance of your sharing request.</td>
				</tr>
				<tr>
					<td>Briefly Plus billing</td>
					<td>Email, internal account ID, Stripe customer/subscription/price/payment/refund IDs, status, billing dates, webhook event IDs, and historical records from the discontinued voice-credit feature. Stripe separately receives payment, billing-address, and tax details.</td>
					<td>Start and administer subscriptions, prevent duplicate allocations, collect or refund payment, and keep required accounting records.</td>
					<td>Contract and legal obligations; fraud prevention is a legitimate interest.</td>
				</tr>
				<tr>
					<td>Support and rights requests</td>
					<td>Your email, message, and any information you include.</td>
					<td>Reply, resolve a problem, verify identity where necessary, and document compliance.</td>
					<td>Contract, legal obligation, or legitimate interests, depending on the request.</td>
				</tr>
			</tbody>
		</table>
		<p>
			We do not use your data for advertising, sell personal data, build marketing profiles, or
			use solely automated decision-making that produces legal or similarly significant effects.
			Please do not put special-category or highly sensitive personal data in a public share link.
		</p>
	</section>

	<section>
		<h2>3. Where data comes from</h2>
		<ul>
			<li>Directly from you when you sign in, connect a provider, subscribe, contact us, or publish a document.</li>
			<li>From Apple when it confirms your account email for Sign in with Apple. CloudKit file content passes directly between Apple and your device.</li>
			<li>From Google when it confirms your account email and returns OAuth credentials or Drive files within the narrow <code>drive.file</code> permission.</li>
			<li>From Stripe when it reports checkout, subscription, and refund status.</li>
			<li>Automatically from your device and network when it requests the service.</li>
			<li>From a share-link owner when that person publishes content that contains information about somebody else.</li>
		</ul>
	</section>

	<section>
		<h2>4. Providers and recipients</h2>
		<p>We disclose only what is needed to operate the feature concerned:</p>
		<table>
			<thead>
				<tr>
					<th>Provider</th>
					<th>Role and data</th>
				</tr>
			</thead>
			<tbody>
				<tr>
					<td><a href="https://www.cloudflare.com/privacypolicy/" rel="noreferrer">Cloudflare</a></td>
					<td>Hosting, database, object storage, content delivery, and security; processes account, share, billing, request, and technical data for Briefly.</td>
				</tr>
				<tr>
					<td><a href="https://policies.google.com/privacy" rel="noreferrer">Google</a></td>
					<td>Optional sign-in and Drive storage/API access; processes account information, OAuth data, and the files held in your Google account.</td>
				</tr>
				<tr>
					<td><a href="https://www.apple.com/legal/privacy/" rel="noreferrer">Apple</a></td>
					<td>Optional account sign-in and private CloudKit storage; processes account information, authentication data, and the records and assets held in your iCloud account.</td>
				</tr>
				<tr>
					<td><a href="https://stripe.com/privacy" rel="noreferrer">Stripe</a></td>
					<td>Checkout, subscriptions, payment, invoicing, tax, and fraud prevention. Stripe acts under its own legal obligations for some payment processing.</td>
				</tr>
				<tr>
					<td><a href="https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement" rel="noreferrer">GitHub</a></td>
					<td>Hosts desktop downloads. GitHub receives normal request data only when you follow a download link.</td>
				</tr>
			</tbody>
		</table>
		<p>
			We may also disclose information where law requires it, to protect users and the service,
			or in a reorganization with appropriate confidentiality and transparency safeguards. We do
			not disclose your private library to other Briefly users. A public share is available to
			anyone who obtains its link.
		</p>
	</section>

	<section>
		<h2>5. International transfers</h2>
		<p>
			Some providers operate globally, including in the United States. As a result, personal data
			may be processed outside the European Economic Area. Where a destination does not benefit
			from an EU adequacy decision, we rely on provider contractual safeguards such as the
			European Commission's Standard Contractual Clauses, together with supplementary measures
			where appropriate. Providers may also rely on an applicable adequacy framework for
			certified entities.
		</p>
		<p>
			You can ask for more information about the relevant safeguard by emailing us. Provider
			terms include the
			<a href="https://www.cloudflare.com/cloudflare-customer-dpa/" rel="noreferrer">Cloudflare DPA</a>,
			<a href="https://cloud.google.com/terms/data-processing-addendum" rel="noreferrer">Google data-processing terms</a>,
			and <a href="https://stripe.com/legal/dpa" rel="noreferrer">Stripe DPA</a>.
		</p>
	</section>

	<section>
		<h2>6. How long we keep data</h2>
		<table>
			<thead>
				<tr>
					<th>Data</th>
					<th>Retention</th>
				</tr>
			</thead>
			<tbody>
				<tr>
					<td>OAuth state</td>
					<td>Intended to expire after 10 minutes and removed during subsequent connection attempts.</td>
				</tr>
				<tr>
					<td>Sign-in session</td>
					<td>Up to 90 days, until you sign out, or until the session is otherwise revoked.</td>
				</tr>
				<tr>
					<td>Google connection</td>
					<td>Until you disconnect Google or ask us to delete the account data. Disconnecting deletes the stored connection credentials.</td>
				</tr>
				<tr>
					<td>Google Drive files</td>
					<td>Controlled by you in your Google account. Disconnecting Briefly does not delete your Drive files.</td>
				</tr>
				<tr>
					<td>iCloud records</td>
					<td>Controlled by you in your Apple account. Stopping iCloud sync does not delete private CloudKit records.</td>
				</tr>
				<tr>
					<td>Public shares</td>
					<td>Until you revoke or replace the share. Revocation deletes its text from Briefly's active systems; provider backups may age out later.</td>
				</tr>
				<tr>
					<td>Billing and transaction records</td>
					<td>For the subscription and then as long as German tax, commercial, fraud-prevention, dispute, and other legal obligations require. Depending on the record, statutory retention is generally 6, 8, or 10 years; accounting vouchers are generally retained for 8 years.</td>
				</tr>
				<tr>
					<td>Support and rights requests</td>
					<td>Normally up to 2 years after closure, longer only where needed for a dispute or legal obligation.</td>
				</tr>
				<tr>
					<td>Local browser data</td>
					<td>Until you clear Briefly's site data or uninstall/remove it. See the <a href="/cookies">Cookies & Local Storage Notice</a>.</td>
				</tr>
			</tbody>
		</table>
		<p>
			We may retain a minimal record where required by law or necessary to establish, exercise,
			or defend legal claims. When retention ends, data is deleted or irreversibly anonymized.
		</p>
	</section>

	<section>
		<h2>7. Your choices and rights</h2>
		<p>Depending on the circumstances, the GDPR gives you the right to:</p>
		<ul>
			<li>access your personal data and receive a copy;</li>
			<li>correct inaccurate or incomplete data;</li>
			<li>request erasure or restriction of processing;</li>
			<li>receive data you provided in a structured, commonly used, machine-readable format;</li>
			<li>object to processing based on legitimate interests;</li>
			<li>withdraw consent where processing relies on consent, without affecting earlier processing; and</li>
			<li>lodge a complaint with a supervisory authority.</li>
		</ul>
		<p>
			Email <a href="mailto:hello@readbriefly.fyi">hello@readbriefly.fyi</a> to exercise a
			right. We may ask for limited information to verify that the request concerns your account.
			We will respond without undue delay and normally within one month. Rights can have lawful
			exceptions—for example, records we must keep for tax or legal claims.
		</p>
		<p>
			Briefly's competent supervisory authority is the
			<a href="https://www.baden-wuerttemberg.datenschutz.de/kontakt-aufnehmen/" rel="noreferrer">State Commissioner for Data Protection and Freedom of Information Baden-Württemberg (LfDI BW)</a>.
			You may also complain to the authority where you live or work, or where you believe an
			infringement occurred. The
			<a href="https://www.datenschutzkonferenz-online.de/datenschutzaufsichtsbehoerden.html" rel="noreferrer">German Data Protection Conference</a>
			lists all federal and state authorities. We would appreciate the chance to resolve your
			concern first, but you do not have to contact us before complaining.
		</p>
	</section>

	<section>
		<h2>8. Security, children, and changes</h2>
		<p>
			Briefly uses encrypted transport, secure HTTP-only session cookies, same-origin checks, and
			encryption for stored Google credentials. Access is scoped to the signed-in account.
			iCloud content is protected by Apple's private CloudKit database and does not
			pass through Briefly's Worker. No internet service is risk-free, so protect forwardable share links and revoke a
			link if it reaches the wrong person.
		</p>
		<p>
			Briefly is not directed to children under 16, and we do not knowingly create their accounts
			without authorization from a parent or guardian where required. Contact us if you believe a
			child has provided data improperly.
		</p>
		<p>
			We will update this notice when our processing materially changes. The current version and
			date will remain available here. If a change materially affects an account holder, we will
			use a reasonable in-product or direct notice where practicable.
		</p>
	</section>
</LegalShell>
