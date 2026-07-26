<script lang="ts">
	import LegalShell from '$lib/LegalShell.svelte';
</script>

<LegalShell
	active="terms"
	title="Terms of service"
	description="The agreement for using Briefly's apps, website, connected services, public shares, and Briefly Plus."
>
	<section>
		<h2>1. Agreement and operator</h2>
		<p>
			These Terms are an agreement between you and <strong>Jonathan Schaul</strong>, operating
			Briefly in Germany (“Briefly”, “we”, or “us”). They apply to the Briefly website,
			desktop and web apps, accounts, synchronization, narration, share links, downloads, and
			Briefly Plus (together, the “Service”).
		</p>
		<p>
			By creating an account, using a connected feature, or subscribing, you agree to these
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
			Briefly helps you capture sources and notes into a local Markdown library, read them at
			different levels of detail, generate optional narration, synchronize selected files through
			your Google Drive, and deliberately publish individual documents using share links.
		</p>
		<ul>
			<li><strong>Briefly membership</strong> is a recurring subscription for the desktop and web apps, cross-device Google Drive synchronization, and public share links.</li>
			<li>An account and active membership are required to access the apps and downloads.</li>
			<li>Features may require a supported operating system, browser, internet connection, Google account, or third-party service.</li>
			<li>Desktop builds may be labelled beta. Back up important source material and do not use Briefly as the sole copy of irreplaceable data.</li>
		</ul>
		<p>
			Generated summaries, extraction, metadata, and narration may contain errors or omissions.
			They are aids, not professional legal, medical, financial, or other expert advice. Check
			important information against the original source.
		</p>
	</section>

	<section>
		<h2>3. Accounts and security</h2>
		<p>
			You are responsible for your Google account, devices, access to your email, and activity
			under your Briefly session. Keep access secure, sign out on shared devices, and tell us
			promptly if you suspect unauthorized use. You may not transfer, sell, or lend an account in
			a way that defeats authentication, pricing, or security controls.
		</p>
		<p>
			The Google Drive connection is optional and can be disconnected in the app. Disconnecting
			Google does not delete the Briefly files in your Drive. Signing out does not cancel Briefly
			Plus or remove purchased AI voice credit.
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
	</section>

	<section>
		<h2>6. Briefly Plus, payment, and cancellation</h2>
		<ul>
			<li>Briefly Plus is billed monthly in advance at the price and currency shown before checkout, plus applicable taxes disclosed by Stripe.</li>
			<li>Your launch-tier monthly price remains fixed while that subscription stays continuously active. If it ends and you later resubscribe, the then-current available price applies.</li>
			<li>You authorize Stripe to charge the payment method associated with your subscription each billing period until cancellation.</li>
			<li>You can cancel at any time in the Stripe billing portal opened from Briefly. Unless law or the checkout states otherwise, cancellation takes effect at the end of the paid billing period and does not retroactively refund an already-started period.</li>
			<li>If payment fails, access to Plus features may be limited or suspended after Stripe's retry process. Your locally stored or Google Drive files remain yours.</li>
			<li>We may change future prices with advance notice. A change does not override the continuous launch-tier promise unless you agree, the subscription ends, or a tax or legal requirement independently changes the amount due.</li>
		</ul>

		<h3>Briefly AI voice credit</h3>
		<ul>
			<li>Purchased AI voice credit is a limited, non-transferable right to use Briefly's managed narration service. It is not money, a bank account, or a general-purpose wallet and cannot be sent to another person or payment destination.</li>
			<li>Your account's first successfully paid Briefly Plus Checkout receives a one-time AI voice credit equal to the total EUR amount paid. Renewals and later subscriptions do not grant another welcome credit.</li>
			<li>Top-up payments include applicable VAT. The credit added to your balance equals the payment excluding VAT, as calculated by Stripe. Pricing changes apply prospectively and do not reduce credit already purchased.</li>
			<li>Briefly reserves the displayed charge before requesting narration, settles successful generations, and restores the reservation when the provider request fails. A completed provider generation is chargeable even if you dislike its style or choose not to listen.</li>
			<li>Purchased and welcome credit have no short product expiry.</li>
			<li>Top-ups are final and non-refundable except where withdrawal, defect, termination, or refund rights are required by law.</li>
		</ul>

		<h3>German and EEA consumer right of withdrawal</h3>
		<p>
			If you are a consumer in Germany or elsewhere in the EEA, you generally have 14 days from
			concluding an online service contract to withdraw without giving a reason. When you choose
			to activate Plus immediately, you request performance during that period. If you withdraw
			after service has begun, the law may permit a proportionate charge for service supplied
			before your notice. Your right does not expire merely because access begins; statutory
			rules on full performance and your express consent remain unaffected.
		</p>
		<p>
			To withdraw from Plus or an AI voice top-up, email an unambiguous statement to
			<a href="mailto:hello@readbriefly.fyi">hello@readbriefly.fyi</a> before the deadline. You
			may use this optional model:
		</p>
		<div class="withdrawal-form">
			<p>To: Briefly · hello@readbriefly.fyi</p>
			<p>I hereby give notice that I withdraw from my Briefly Plus contract.</p>
			<p>Ordered on: [date]</p>
			<p>Account email: [email]</p>
			<p>Name: [name]</p>
			<p>Date: [date]</p>
		</div>
		<p>
			This section does not affect your mandatory remedies when a digital service is defective,
			not as described, or not supplied. Refunds required by law will be provided.
		</p>
	</section>

	<section>
		<h2>7. Third-party services</h2>
		<p>
			Briefly interoperates with Google Drive, Stripe, OpenRouter, GitHub, operating systems, and
			browsers. Their services and terms are separate from ours. We are responsible for Briefly,
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
			improvement. For a paid continuous service, we will provide updates and remedies required
			by applicable consumer law.
		</p>
		<p>
			You may stop using Briefly at any time. Cancel Plus separately, revoke public shares you no
			longer want online, and contact us to request deletion of server-side account data. We may
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
			€100; for paid business use, it is limited to the fees paid for Plus in the 12 months before
			the event. These business caps do not apply to consumers where mandatory law provides a
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
			version and date. If a material change affects an existing paid subscription, we will give
			reasonable advance notice and, where required, ask for agreement or allow termination.
		</p>
	</section>
</LegalShell>
