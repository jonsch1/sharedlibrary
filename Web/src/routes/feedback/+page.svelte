<script lang="ts">
	import { onMount } from 'svelte';
	import ChevronUpIcon from '@lucide/svelte/icons/chevron-up';
	import LogInIcon from '@lucide/svelte/icons/log-in';
	import SendIcon from '@lucide/svelte/icons/send';

	type FeedbackItem = {
		id: string;
		title: string;
		details: string;
		createdAt: number;
		upvotes: number;
		upvoted: boolean;
	};

	const dateFormatter = new Intl.DateTimeFormat(undefined, {
		month: 'short',
		day: 'numeric',
		year: 'numeric'
	});

	let items = $state<FeedbackItem[]>([]);
	let authenticated = $state(false);
	let loading = $state(true);
	let submitting = $state(false);
	let voting = $state('');
	let title = $state('');
	let details = $state('');
	let message = $state('');

	onMount(() => {
		void loadFeedback();
	});

	async function loadFeedback(): Promise<void> {
		try {
			const response = await fetch('/api/feedback', { cache: 'no-store' });
			const value = await response.json();
			if (!response.ok) throw new Error(value.error ?? 'Feedback could not be loaded.');
			items = value.items;
			authenticated = value.authenticated;
		} catch (error) {
			message = error instanceof Error ? error.message : 'Feedback could not be loaded.';
		} finally {
			loading = false;
		}
	}

	async function submitFeedback(event: SubmitEvent): Promise<void> {
		event.preventDefault();
		if (submitting) return;
		submitting = true;
		message = '';
		try {
			const response = await fetch('/api/feedback', {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({ title, details })
			});
			const value = await response.json();
			if (!response.ok) throw new Error(value.error ?? 'Feedback could not be posted.');
			items = [value, ...items];
			title = '';
			details = '';
			message = 'Thanks — your feedback is on the board.';
		} catch (error) {
			message = error instanceof Error ? error.message : 'Feedback could not be posted.';
		} finally {
			submitting = false;
		}
	}

	async function setUpvote(item: FeedbackItem): Promise<void> {
		if (!authenticated) {
			window.location.assign('/api/auth/google/start?return_to=%2Ffeedback');
			return;
		}
		if (voting) return;
		voting = item.id;
		message = '';
		try {
			const response = await fetch(`/api/feedback/${item.id}/upvote`, {
				method: 'PUT',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({ upvoted: !item.upvoted })
			});
			const value = await response.json();
			if (!response.ok) throw new Error(value.error ?? 'Your upvote could not be saved.');
			item.upvotes = value.upvotes;
			item.upvoted = value.upvoted;
			items = [...items].sort(
				(left, right) => right.upvotes - left.upvotes || right.createdAt - left.createdAt
			);
		} catch (error) {
			message = error instanceof Error ? error.message : 'Your upvote could not be saved.';
		} finally {
			voting = '';
		}
	}
</script>

<svelte:head>
	<title>Feedback — Briefly</title>
	<meta
		name="description"
		content="Suggest and upvote improvements for Briefly."
	/>
</svelte:head>

<main class="feedback-page">
	<header>
		<a class="brand" href="/landing">
			<img src="/icons/icon-192.png" alt="" />
			<span>Briefly</span>
		</a>
	</header>

	<div class="feedback-shell">
		<section class="intro">
			<p class="eyebrow">Community feedback</p>
			<h1>Help shape Briefly.</h1>
			<p>Share what would make Briefly better, or upvote an idea you want us to prioritize.</p>
		</section>

		{#if authenticated}
			<form onsubmit={submitFeedback}>
				<label for="feedback-title">What should we improve?</label>
				<input
					id="feedback-title"
					bind:value={title}
					minlength="3"
					maxlength="120"
					placeholder="A short, specific idea"
					required
				/>
				<label for="feedback-details">Details <span>Optional</span></label>
				<textarea
					id="feedback-details"
					bind:value={details}
					maxlength="2000"
					rows="4"
					placeholder="What problem would this solve?"
				></textarea>
				<button type="submit" disabled={submitting}>
					<SendIcon /> {submitting ? 'Posting…' : 'Post feedback'}
				</button>
			</form>
		{:else if !loading}
			<a class="sign-in" href="/api/auth/google/start?return_to=%2Ffeedback">
				<LogInIcon />
				<span><strong>Sign in to post and upvote</strong>Read the board without an account.</span>
			</a>
		{/if}

		{#if message}<p class="message" role="status">{message}</p>{/if}

		<section class="board" aria-labelledby="board-title" aria-busy={loading}>
			<div class="board-heading">
				<h2 id="board-title">Ideas</h2>
				<span>{items.length} {items.length === 1 ? 'suggestion' : 'suggestions'}</span>
			</div>

			{#if loading}
				<p class="empty">Loading feedback…</p>
			{:else if items.length === 0}
				<p class="empty">No suggestions yet. Start the board with your idea.</p>
			{:else}
				<div class="items">
					{#each items as item (item.id)}
						<article>
							<button
								class="upvote"
								class:active={item.upvoted}
								disabled={voting === item.id}
								aria-label={`${item.upvoted ? 'Remove upvote from' : 'Upvote'} ${item.title}`}
								aria-pressed={item.upvoted}
								onclick={() => setUpvote(item)}
							>
								<ChevronUpIcon />
								<strong>{item.upvotes}</strong>
							</button>
							<div>
								<h3>{item.title}</h3>
								{#if item.details}<p>{item.details}</p>{/if}
								<time datetime={new Date(item.createdAt).toISOString()}>
									{dateFormatter.format(item.createdAt)}
								</time>
							</div>
						</article>
					{/each}
				</div>
			{/if}
		</section>
	</div>
</main>

<style>
	:global(body) {
		overflow: auto;
		background: #eeebdf;
	}

	.feedback-page {
		min-height: 100dvh;
		padding: 24px;
		background:
			radial-gradient(circle at 12% 0%, rgb(237 176 91 / 18%), transparent 30%),
			linear-gradient(145deg, #f5f2e8, #e5e1d5);
		color: #171714;
	}

	header,
	.feedback-shell {
		width: min(760px, 100%);
		margin: 0 auto;
	}

	header {
		display: flex;
		align-items: center;
		justify-content: space-between;
	}

	a {
		color: inherit;
	}

	.brand,
	.sign-in,
	button {
		display: inline-flex;
		align-items: center;
	}

	.brand {
		gap: 9px;
		font-weight: 750;
		text-decoration: none;
	}

	.brand img {
		width: 34px;
		height: 34px;
		border-radius: 10px;
	}

	.feedback-shell {
		padding: 72px 0 100px;
	}

	.intro {
		max-width: 610px;
	}

	.eyebrow {
		margin: 0 0 10px;
		color: #747168;
		font-size: 11px;
		font-weight: 750;
		letter-spacing: 0.13em;
		text-transform: uppercase;
	}

	h1 {
		margin: 0;
		font-size: clamp(42px, 8vw, 68px);
		font-weight: 770;
		letter-spacing: -0.055em;
		line-height: 0.98;
	}

	.intro > p:last-child {
		margin: 22px 0 0;
		color: #5e5b53;
		font-size: 17px;
		line-height: 1.6;
	}

	form,
	.sign-in {
		margin-top: 42px;
		border: 1px solid rgb(29 29 25 / 17%);
		border-radius: 20px;
		background: rgb(250 248 240 / 78%);
		box-shadow: 0 18px 45px rgb(57 48 31 / 8%);
	}

	form {
		display: grid;
		padding: 24px;
	}

	label {
		margin: 0 0 8px;
		font-size: 13px;
		font-weight: 700;
	}

	label:not(:first-child) {
		margin-top: 18px;
	}

	label span {
		color: #858178;
		font-weight: 500;
	}

	input,
	textarea {
		box-sizing: border-box;
		width: 100%;
		border: 1px solid rgb(29 29 25 / 22%);
		border-radius: 11px;
		outline: none;
		background: #fffdf7;
		color: inherit;
		font: inherit;
	}

	input {
		height: 46px;
		padding: 0 13px;
	}

	textarea {
		padding: 12px 13px;
		resize: vertical;
		line-height: 1.5;
	}

	input:focus,
	textarea:focus {
		border-color: #171714;
		box-shadow: 0 0 0 3px rgb(23 23 20 / 8%);
	}

	form button {
		justify-self: start;
		gap: 8px;
		margin-top: 20px;
		padding: 11px 15px;
		border: 0;
		border-radius: 10px;
		background: #191917;
		color: #fffdf7;
		font: inherit;
		font-size: 13px;
		font-weight: 700;
		cursor: pointer;
	}

	form button :global(svg) {
		width: 16px;
	}

	button:disabled {
		cursor: wait;
		opacity: 0.55;
	}

	.sign-in {
		gap: 14px;
		padding: 20px 22px;
		text-decoration: none;
	}

	.sign-in :global(svg) {
		width: 20px;
	}

	.sign-in span {
		display: grid;
		gap: 3px;
		color: #69665e;
		font-size: 13px;
	}

	.sign-in strong {
		color: #171714;
		font-size: 14px;
	}

	.message {
		margin: 18px 2px 0;
		color: #5f5c54;
		font-size: 13px;
	}

	.board {
		margin-top: 58px;
	}

	.board-heading {
		display: flex;
		align-items: baseline;
		justify-content: space-between;
		margin-bottom: 14px;
	}

	h2 {
		margin: 0;
		font-size: 25px;
		letter-spacing: -0.035em;
	}

	.board-heading span,
	time {
		color: #817e75;
		font-size: 11px;
	}

	.items {
		overflow: hidden;
		border: 1px solid rgb(29 29 25 / 17%);
		border-radius: 18px;
		background: rgb(250 248 240 / 72%);
	}

	article {
		display: grid;
		grid-template-columns: 54px 1fr;
		gap: 18px;
		padding: 22px;
	}

	article + article {
		border-top: 1px solid rgb(29 29 25 / 12%);
	}

	.upvote {
		align-self: start;
		flex-direction: column;
		gap: 1px;
		width: 50px;
		padding: 7px 4px 8px;
		border: 1px solid rgb(29 29 25 / 18%);
		border-radius: 11px;
		background: #f4f1e7;
		color: #5e5b54;
		font: inherit;
		cursor: pointer;
	}

	.upvote:hover,
	.upvote.active {
		border-color: #d69328;
		background: #f8d99e;
		color: #6e4310;
	}

	.upvote :global(svg) {
		width: 18px;
		height: 18px;
	}

	.upvote strong {
		font-size: 13px;
	}

	h3 {
		margin: 1px 0 0;
		font-size: 17px;
		letter-spacing: -0.02em;
	}

	article p {
		margin: 8px 0 11px;
		color: #5f5c55;
		font-size: 14px;
		line-height: 1.55;
		white-space: pre-wrap;
	}

	.empty {
		padding: 44px 22px;
		border: 1px dashed rgb(29 29 25 / 22%);
		border-radius: 18px;
		color: #747168;
		text-align: center;
	}

	@media (max-width: 600px) {
		.feedback-page {
			padding: 18px;
		}

		.feedback-shell {
			padding-top: 54px;
		}

		h1 {
			font-size: 46px;
		}

		article {
			gap: 13px;
			padding: 18px 15px;
		}
	}
</style>
