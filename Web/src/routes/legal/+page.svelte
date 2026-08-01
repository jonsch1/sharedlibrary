<script lang="ts">
	import LegalShell from '$lib/LegalShell.svelte';
</script>

<LegalShell
	active="overview"
	title="Legal overview"
	description="The plain-language policies that govern Briefly and explain how the service handles your data."
>
	<section>
		<h2>Clear rules, without the fog.</h2>
		<p>
			Briefly is designed around a local-first library. Your private library stays on your
			device, while iCloud provides private synchronization across your Apple devices.
			Server-side copies are limited to the account, entitlement, and share-link data needed to
			provide the features you request.
		</p>

		<div class="legal-cards">
			<a class="legal-card" href="/privacy">
				<span>01 · Data</span>
				<div>
					<h2>Privacy notice</h2>
					<p>What we process, why, for how long, and the rights you can exercise.</p>
				</div>
			</a>
			<a class="legal-card" href="/terms">
				<span>02 · Agreement</span>
				<div>
					<h2>Terms of service</h2>
					<p>The rules for accounts, content, public sharing, and your Briefly membership.</p>
				</div>
			</a>
			<a class="legal-card" href="/cookies">
				<span>03 · Your device</span>
				<div>
					<h2>Cookies & storage</h2>
					<p>The one essential cookie and the offline data stored in your browser.</p>
				</div>
			</a>
			<a class="legal-card" href="/imprint">
				<span>04 · Provider</span>
				<div>
					<h2>Imprint</h2>
					<p>The operator identity, business address, and legal contact information.</p>
				</div>
			</a>
		</div>
	</section>

	<section>
		<h2>Service operator</h2>
		<p>
			Briefly is operated by <strong>Jonathan Schaul</strong>, Lutherstr. 36, 69120 Heidelberg,
			Germany. “Briefly” and “we” on these pages refer to that service. For privacy requests,
			support, or legal notices, email
			<a href="mailto:hello@readbriefly.fyi">hello@readbriefly.fyi</a>.
		</p>
		<p>
			Briefly's competent supervisory authority is the
			<a href="https://www.baden-wuerttemberg.datenschutz.de/kontakt-aufnehmen/" rel="noreferrer">State Commissioner for Data Protection and Freedom of Information Baden-Württemberg (LfDI BW)</a>.
			You may contact it, or the authority where you live or work, if you believe your
			data-protection rights have not been respected.
		</p>
	</section>

	<section>
		<h2>Which documents apply?</h2>
		<ul>
			<li>The <a href="/privacy">Privacy Notice</a> applies whenever Briefly processes personal data.</li>
			<li>The <a href="/terms">Terms of Service</a> apply when you use the website, apps, accounts, synchronization, public sharing, or a Briefly membership.</li>
			<li>The <a href="/cookies">Cookies & Local Storage Notice</a> explains data stored on your browser or device.</li>
			<li>The <a href="/imprint">Imprint</a> identifies the service operator under German law.</li>
			<li>Mandatory consumer and data-protection law always prevails over a conflicting term.</li>
		</ul>
	</section>
</LegalShell>
