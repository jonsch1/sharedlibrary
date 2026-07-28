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
        class="depth-step depth-step-{depth} border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-full! border shadow-sm! hover:bg-secondary/80! [&.is-active]:border-primary! [&.is-active]:bg-accent! [&.is-active]:text-accent-foreground! focus-visible:ring-3 focus-visible:ring-ring/30"
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
        class="depth-step original-step border-border! bg-secondary! bg-none! text-secondary-foreground! rounded-full! border shadow-sm! hover:bg-secondary/80! [&.is-active]:border-primary! [&.is-active]:bg-accent! [&.is-active]:text-accent-foreground! focus-visible:ring-3 focus-visible:ring-ring/30"
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
    height: 50px;
    align-items: center;
    justify-content: center;
    gap: 4px;
  }

  .depth-slot {
    position: relative;
    display: grid;
    width: 40px;
    height: 50px;
    flex: 0 0 40px;
    place-items: center;
  }

  .depth-step {
    position: absolute;
    display: grid;
    width: 36px;
    height: 36px;
    margin: 0;
    padding: 0;
    place-items: center;
    border-radius: 50%;
    cursor: pointer;
    isolation: isolate;
    -webkit-tap-highlight-color: transparent;
    transition:
      width 240ms cubic-bezier(0.2, 0.8, 0.2, 1),
      height 240ms cubic-bezier(0.2, 0.8, 0.2, 1),
      transform 170ms ease;
  }

  .depth-step-core {
    display: grid;
    width: 36px;
    height: 36px;
    place-items: center;
    border-radius: 50%;
    transition:
      width 240ms cubic-bezier(0.2, 0.8, 0.2, 1),
      height 240ms cubic-bezier(0.2, 0.8, 0.2, 1),
      box-shadow 240ms ease,
      background 240ms ease,
      border-color 240ms ease;
  }

  .depth-step.is-active {
    z-index: 2;
    width: 48px;
    height: 48px;
  }

  .depth-step.is-active .depth-step-core {
    width: 38px;
    height: 38px;
  }

  .depth-icon {
    display: block;
    width: 22px;
    height: 22px;
    fill: currentColor;
  }

  .original-icon {
    display: grid;
    width: 19px;
    height: 19px;
    place-items: center;
    transition:
      width 240ms cubic-bezier(0.2, 0.8, 0.2, 1),
      height 240ms cubic-bezier(0.2, 0.8, 0.2, 1);
  }

  .original-icon :global(svg) {
    width: 100%;
    height: 100%;
    stroke-width: 2.25;
  }

  .original-step.is-active .original-icon {
    width: 22px;
    height: 22px;
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
      transform: translateY(-2px);
    }
  }

  .depth-step:active {
    transform: translateY(1px) scale(0.985);
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
      width: 40px;
      height: 40px;
    }

    .segmented-depth--compact .depth-step.is-active .depth-step-core {
      width: 32px;
      height: 32px;
    }

    .segmented-depth--compact .depth-icon {
      width: 18px;
      height: 18px;
    }

    .segmented-depth--compact .original-icon {
      width: 16px;
      height: 16px;
    }

    .segmented-depth--compact .original-step.is-active .original-icon {
      width: 18px;
      height: 18px;
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .depth-step,
    .depth-step-core {
      transition-duration: 0.01ms;
    }
  }
</style>
