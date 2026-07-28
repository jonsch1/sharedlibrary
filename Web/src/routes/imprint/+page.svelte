<script lang="ts">
	import LegalShell from '$lib/LegalShell.svelte';
</script>

<svelte:head>
	<meta name="robots" content="noindex, follow" />
</svelte:head>

<LegalShell
	active="imprint"
	title="Imprint (Impressum)"
	description="Provider identification and contact details for Briefly under German law."
>
	<section>
		<h2>Information pursuant to § 5 DDG</h2>
		<p>
			<strong>Jonathan Schaul</strong><br />
			Briefly<br />
			Lutherstr. 36<br />
			69120 Heidelberg<br />
			Germany
		</p>

		<h3>Contact</h3>
		<p>
			Email: <a href="mailto:hello@readbriefly.fyi">hello@readbriefly.fyi</a>
		</p>
	</section>

	<section>
		<h2>Service and content</h2>
		<p>
			Briefly provides software for capturing, organizing, reading, synchronizing, creating scheduled
			podcast episodes, and sharing documents. Users remain responsible for content they add or deliberately publish
			through a share link. Reports concerning the service or a public share can be sent to
			<a href="mailto:hello@readbriefly.fyi">hello@readbriefly.fyi</a>.
		</p>
		<p>
			For information about personal-data processing, see the
			<a href="/privacy">Privacy Notice</a>. The <a href="/terms">Terms of Service</a> govern
			use of Briefly.
		</p>
	</section>
</LegalShell>
