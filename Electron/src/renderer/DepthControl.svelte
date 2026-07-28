<script lang="ts">
	import FileTextIcon from '@lucide/svelte/icons/file-text';
	import type { LibraryVariant } from '../shared/contracts';

	let {
		variants,
		selected,
		onselect,
		presentation = 'compact'
	}: {
		variants: LibraryVariant[];
		selected: LibraryVariant;
		onselect: (variant: LibraryVariant) => void;
		presentation?: 'compact' | 'showcase';
	} = $props();

	const variantOrder: LibraryVariant[] = ['brief', 'concise', 'detailed', 'comprehensive'];
	const summaryVariants = $derived(variants.filter((variant) => variant !== 'source'));
	const hasSource = $derived(variants.includes('source'));
	// Material Icons: horizontal_rule, short_text, notes, subject (Apache-2.0).
	const depthIconPaths = [
		'M4 11h16v2H4z',
		'M4 9h16v2H4V9zm0 4h10v2H4v-2z',
		'M3 18h12v-2H3v2zm0-12v2h18V6H3zm0 7h18v-2H3v2z',
		'M14 17H4v2h10v-2zm6-8H4v2h16V9zM4 15h16v-2H4v2zM4 5v2h16V5H4z'
	];

	const variantNames: Record<LibraryVariant, string> = {
		brief: 'Brief',
		concise: 'Concise',
		detailed: 'Detailed',
		comprehensive: 'Comprehensive',
		source: 'Original'
	};
</script>

<div
	class="segmented-depth segmented-depth--{presentation}"
	role="radiogroup"
	aria-label="Reading version"
>
	{#each summaryVariants as variant}
		{@const depth = variantOrder.indexOf(variant) + 1}
		<span class="depth-slot">
      <button
        type="button"
        class="depth-step depth-step-{depth}"
				class:is-active={selected === variant}
				role="radio"
				aria-checked={selected === variant}
				aria-label={variantNames[variant]}
				title={variantNames[variant]}
				onclick={() => onselect(variant)}
			>
				<span class="depth-step-core">
					<svg class="depth-icon" viewBox="0 0 24 24" aria-hidden="true">
						<path d={depthIconPaths[depth - 1]} />
					</svg>
				</span>
			</button>
		</span>
	{/each}
	{#if hasSource}
		<span class="depth-slot original-slot">
      <button
        type="button"
        class="depth-step original-step"
				class:is-active={selected === 'source'}
				role="radio"
				aria-checked={selected === 'source'}
				aria-label={variantNames.source}
				title={variantNames.source}
				onclick={() => onselect('source')}
			>
				<span class="depth-step-core original-step-core">
					<span class="original-icon" aria-hidden="true">
						<FileTextIcon />
					</span>
				</span>
			</button>
		</span>
	{/if}
</div>

<style>
  .segmented-depth {
    display: flex;
    min-width: 0;
    height: 40px;
    align-items: center;
    justify-content: center;
    gap: 2px;
  }

  .depth-slot {
    position: relative;
    display: grid;
    width: 38px;
    height: 40px;
    flex: 0 0 38px;
    place-items: center;
  }

  .depth-step {
    display: grid;
    width: 38px;
    height: 38px;
    margin: 0;
    padding: 0;
    place-items: center;
    border-radius: 10px;
    color: var(--document-action-foreground);
    cursor: pointer;
    -webkit-tap-highlight-color: transparent;
    transition:
      background 160ms ease,
      color 160ms ease;
  }

  .depth-step-core {
    display: grid;
    width: 38px;
    height: 38px;
    place-items: center;
    border-radius: inherit;
  }

  .depth-step.is-active {
    background: var(--document-action-active);
    box-shadow: var(--document-action-active-shadow);
    color: var(--document-action-active-foreground);
  }

  .depth-icon {
    display: block;
    width: 21px;
    height: 21px;
    fill: currentColor;
  }

  .original-icon {
    display: grid;
    width: 19px;
    height: 19px;
    place-items: center;
  }

  .original-icon :global(svg) {
    width: 100%;
    height: 100%;
    stroke-width: 2.25;
  }

  .segmented-depth--showcase {
    height: 76px;
    gap: 8px;
  }

  .segmented-depth--showcase .depth-slot {
    width: 58px;
    height: 76px;
    flex-basis: 58px;
  }

  .segmented-depth--showcase .depth-step,
  .segmented-depth--showcase .depth-step-core {
    width: 52px;
    height: 52px;
  }

  .segmented-depth--showcase .depth-step.is-active {
    width: 70px;
    height: 70px;
  }

  .segmented-depth--showcase .depth-step.is-active .depth-step-core {
    width: 54px;
    height: 54px;
  }

  .segmented-depth--showcase .depth-icon {
    width: 30px;
    height: 30px;
  }

  .segmented-depth--showcase .original-icon {
    width: 27px;
    height: 27px;
  }

  .segmented-depth--showcase .original-step.is-active .original-icon {
    width: 31px;
    height: 31px;
  }

  @media (hover: hover) {
    .depth-step:hover:not(.is-active) {
      background: var(--document-action-hover);
      color: var(--document-action-hover-foreground);
    }
  }

  .depth-step:active:not(.is-active) {
    background: var(--document-action-pressed);
    color: var(--document-action-pressed-foreground);
  }

  .depth-step:focus-visible {
    outline: 2px solid var(--document-action-focus);
    outline-offset: 1px;
  }

  @media (max-width: 680px) {
    .segmented-depth--compact {
      grid-area: variant;
      width: 100%;
      height: 40px;
      align-self: end;
      gap: 2px;
      padding: 0 7px;
    }

    .segmented-depth--compact .depth-slot {
      width: 34px;
      height: 40px;
      flex-basis: 34px;
    }

    .segmented-depth--compact .depth-step,
    .segmented-depth--compact .depth-step-core {
      width: 30px;
      height: 30px;
    }

    .segmented-depth--compact .depth-step.is-active {
      width: 30px;
      height: 30px;
    }

    .segmented-depth--compact .depth-step.is-active .depth-step-core {
      width: 30px;
      height: 30px;
    }

    .segmented-depth--compact .depth-icon {
      width: 18px;
      height: 18px;
    }

    .segmented-depth--compact .original-icon {
      width: 16px;
      height: 16px;
    }

  }

  @media (prefers-reduced-motion: reduce) {
    .depth-step,
    .depth-step-core {
      transition-duration: 0.01ms;
    }
  }
</style>
