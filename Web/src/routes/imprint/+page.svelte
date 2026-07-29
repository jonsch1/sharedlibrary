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
	updated="29 July 2026"
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
			The same email address is Briefly's single electronic point of contact for recipients,
			Member State authorities, the European Commission, and the European Board for Digital
			Services under Articles 11 and 12 of the Digital Services Act. Communications are accepted
			in German or English and are reviewed by a person.
		</p>
		<p>
			For a specific public share, use <strong>Report illegal content</strong> on that reader so
			the notice includes its exact location and the information needed for review.
		</p>
		<p>
			For information about personal-data processing, see the
			<a href="/privacy">Privacy Notice</a>. The <a href="/terms">Terms of Service</a> govern
			use of Briefly.
		</p>
	</section>
</LegalShell>
