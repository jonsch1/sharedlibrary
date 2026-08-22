<script lang="ts">
	import LegalShell from '$lib/LegalShell.svelte';
</script>

<LegalShell
	active="terms"
	title="Terms of service"
	description="The agreement for using Briefly's apps, website, connected services, and public shares."
	updated="6 August 2026"
>
	<section>
		<h2>1. Agreement and operator</h2>
		<p>
			These Terms are an agreement between you and <strong>Jonathan Schaul</strong>, operating
			Briefly in Germany (“Briefly”, “we”, or “us”). They apply to the Briefly website,
			macOS and iOS apps, accounts, synchronization, scheduled voice briefs, and share links
			(together, the “Service”).
		</p>
		<p>
			By creating an account or using a connected feature, you agree to these
			Terms. If you do not agree, do not use those features. The <a href="/privacy">Privacy Notice</a>
			explains how personal data is handled. Provider details are in the
			<a href="/imprint">Imprint</a>. Contact:
			<a href="mailto:hello@readbriefly.fyi">hello@readbriefly.fyi</a>.
		</p>
		<p>
			You must be at least 16, or have valid permission from a parent or legal guardian. If you
			use Briefly for an organization, you confirm that you may accept these Terms for it.
		</p>
	</section>

	<section>
		<h2>2. What Briefly provides</h2>
		<p>
			Briefly helps you capture sources and notes into a local library, read them at
			different levels of detail, watch sources and prepare scheduled voice-brief episodes,
			synchronize through iCloud, and deliberately publish individual documents using share links.
		</p>
		<ul>
			<li>This TestFlight beta is free to use and does not present a Briefly subscription or hosted AI inference.</li>
			<li>Sign in with Apple is optional for local library use. Cross-device and public-sharing features may require a Briefly account and remain subject to the service configuration.</li>
			<li>On macOS, you may provide your own OpenRouter API key or configure a compatible Codex, Claude, Gemini, Pi, or OpenCode CLI. The selected provider's separate terms, privacy policy, usage limits, and charges then apply. iOS does not generate summaries in this beta.</li>
			<li>Features may require a supported Apple operating system, internet connection, Apple account, or third-party service.</li>
			<li>App builds may be labelled beta. Back up important source material and do not use Briefly as the sole copy of irreplaceable data.</li>
		</ul>
		<p>
			Generated summaries, extraction, metadata, and voice-brief episodes may contain errors or omissions.
			They are aids, not professional legal, medical, financial, or other expert advice. Check
			important information against the original source.
		</p>
	</section>

	<section>
		<h2>3. Accounts and security</h2>
		<p>
			You are responsible for your Apple account, devices, access to your email, and activity
			under your Briefly session. Keep access secure, sign out on shared devices, and tell us
			promptly if you suspect unauthorized use. You may not transfer, sell, or lend an account in
			a way that defeats authentication, pricing, or security controls.
		</p>
		<p>
			iCloud sync is optional and can be stopped in the app. Doing so does not
			delete Briefly files already stored in iCloud. You can delete your server-side Briefly
			account in <strong>Settings → Account</strong>; local and private iCloud files remain under
			your control.
		</p>
	</section>

	<section>
		<h2>4. Your content</h2>
		<p>
			You keep ownership of content you add to Briefly. You give us a limited, non-exclusive,
			worldwide licence to host, copy, transmit, format, and otherwise process that content only
			as needed to operate, secure, and support the features you request. This licence ends when
			the content is deleted from the Service, subject to reasonable backup expiry and legal
			retention.
		</p>
		<p>
			You confirm that you have the rights and lawful basis needed to capture, process, and share
			your content. Briefly does not grant you rights to third-party articles, videos, papers,
			images, audio, or other source material. Respect copyright, database rights, privacy,
			confidentiality, paywalls, and the original source's terms.
		</p>

		<h3>Public share links</h3>
		<p>
			A share link is unlisted, not private: anyone with the link can open and forward it. You are
			responsible for reviewing the document and removing secrets, personal data, confidential
			material, or content you may not republish before sharing. You can revoke a link in Briefly;
			people may already have saved copies outside our control.
		</p>
		<p>
			Public readers contain generated or user-edited summaries and, where available, a link to
			the source. Briefly does not publish the captured original text or its narration through a
			public share.
		</p>
	</section>

	<section>
		<h2>5. Acceptable use</h2>
		<p>You must not use Briefly to:</p>
		<ul>
			<li>break the law or infringe intellectual-property, privacy, publicity, confidentiality, or other rights;</li>
			<li>publish unlawful, abusive, deceptive, defamatory, exploitative, or malicious content;</li>
			<li>distribute malware, interfere with the Service, probe for vulnerabilities without written permission, or bypass access/rate limits;</li>
			<li>access another person's account, Drive, content, or share controls without authorization;</li>
			<li>use automated traffic that materially burdens the Service or resell Briefly without written agreement; or</li>
			<li>misrepresent generated material as verified fact where doing so could harm someone.</li>
		</ul>
		<p>
			We may remove a public share, restrict a feature, or suspend access where reasonably
			necessary to stop harm, comply with law, protect the Service, or investigate a material
			breach. Where appropriate, we will give notice and a chance to respond.
		</p>

		<h3>Notice, action, and appeals</h3>
		<p>
			Anyone can use <strong>Report illegal content</strong> on a public share to identify the
			exact content, explain the alleged illegality, and submit the contact and good-faith
			information requested by the form. We acknowledge reports electronically and review them
			in a timely, diligent, objective, and non-arbitrary way. Content-moderation decisions are
			made by a person, not solely by an automated system.
		</p>
		<p>
			We may leave content available, disable the share, or restrict an account depending on the
			report, applicable law, and these Terms. We provide the affected account with the reason
			for a restriction and an appeal route where we know its contact details. Reporters receive
			the decision where contact details are provided. Appeals, copyright counter-notices, and
			questions may be sent to
			<a href="mailto:hello@readbriefly.fyi">hello@readbriefly.fyi</a>.
		</p>
		<p>
			We reasonably implement a policy of terminating accounts that repeatedly use Briefly to
			infringe copyright. A valid counter-notice may lead to restoration where applicable law
			permits and no timely court action prevents it.
		</p>
	</section>

	<section>
		<h2>6. Beta availability and provider charges</h2>
		<ul>
			<li>The TestFlight beta is free and does not present a Briefly subscription or hosted AI inference.</li>
			<li>On macOS, you may provide your own OpenRouter API key or use a compatible provider CLI. The selected provider's separate terms, privacy policy, usage limits, and charges apply to that processing.</li>
			<li>iOS captures and stores items without generating summaries in this beta.</li>
		</ul>
	</section>

	<section>
		<h2>7. Third-party services</h2>
		<p>
			Briefly interoperates with Apple, iCloud, OpenRouter,
			optional third-party AI CLIs such as OpenAI/Codex,
			Modal-hosted transcription and voice generation, Firecrawl extraction, consent-only
			PostHog analytics, operating systems, and browsers. Their services and terms are separate
			from ours. We are responsible for Briefly,
			not for third-party outages, account decisions, content, or changes outside our reasonable
			control. We will use reasonable care when choosing and integrating providers and will not
			use this section to avoid responsibility that mandatory law places on us.
		</p>
	</section>

	<section>
		<h2>8. Briefly's software and brand</h2>
		<p>
			Except for your content and third-party material, the Service—including its design,
			software, documentation, and Briefly name and marks—is owned by us or our licensors. We
			give you a personal, limited, revocable, non-exclusive, non-transferable right to use the
			Service under these Terms. Open-source components remain governed by their own licences.
		</p>
		<p>
			You may send feedback. You allow us to use it without payment or confidentiality
			obligation, but we will not identify you publicly without permission.
		</p>
	</section>

	<section>
		<h2>9. Availability, changes, and ending use</h2>
		<p>
			We aim to keep Briefly reliable but do not promise uninterrupted or error-free operation.
			We may update features for security, compatibility, legal compliance, or product
			improvement. For any connected service, we will provide updates and remedies required by
			applicable consumer law.
		</p>
		<p>
			You may stop using Briefly at any time, revoke public shares you no longer want online, and
			use <strong>Settings → Account → Delete Briefly account</strong>
			to delete server-side account data. You may also contact us for help with a rights request. We may
			end the Service or your access for a material breach, legal requirement, security risk, or
			discontinuation. Where practicable, we will give reasonable notice and an opportunity to
			export or retain your content.
		</p>
	</section>

	<section>
		<h2>10. Responsibility and liability</h2>
		<p>
			Nothing in these Terms excludes or limits liability where doing so is unlawful, including
			mandatory consumer rights and liability for intent, gross negligence, fraud, or death or
			personal injury caused by negligence where applicable.
		</p>
		<p>
			To the extent the law permits, neither side is responsible for indirect or unforeseeable
			loss. Briefly is not responsible for loss caused by your unlawful content, disclosure of a
			forwardable share link, failure to secure your account, or a third-party service outside
			our reasonable control. For business use, Briefly's aggregate liability is limited to
			€100. These business caps do not apply to consumers where mandatory law provides a
			greater remedy.
		</p>
	</section>

	<section>
		<h2>11. Governing law, disputes, and changes</h2>
		<p>
			German law governs these Terms. If you are a consumer, this choice does not deprive you of
			mandatory protection provided by the law of your usual country of residence, and you may
			bring a claim in any court available under mandatory consumer law. Otherwise, the competent
			courts at Briefly's place of establishment in Germany have exclusive jurisdiction where
			the law permits.
		</p>
		<p>
			Please email <a href="mailto:hello@readbriefly.fyi">hello@readbriefly.fyi</a> first so we
			can try to resolve a dispute. You may also use any consumer dispute or court procedure
			available to you by law.
		</p>
		<p>
			We may update these Terms for legal, security, or product reasons. We will post the revised
			version and date. We will give reasonable advance notice of material changes where required
			by applicable law.
		</p>
	</section>
</LegalShell>
