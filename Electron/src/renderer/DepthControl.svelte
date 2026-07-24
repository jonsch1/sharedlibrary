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
					<svg
						class="depth-pie"
						viewBox="0 0 100 100"
						aria-hidden="true"
						shape-rendering="geometricPrecision"
					>
						<path class="slice slice-1" d="M50 50 L50 0 A50 50 0 0 1 95.677 29.663 Z" />
						<path
							class="slice slice-2"
							d="M50 50 L95.677 29.663 A50 50 0 0 1 86.568 84.100 Z"
						/>
						<path
							class="slice slice-3"
							d="M50 50 L86.568 84.100 A50 50 0 0 1 11.698 82.139 Z"
						/>
						<path
							class="slice slice-4"
							d="M50 50 L11.698 82.139 A50 50 0 0 1 3.975 30.463 Z"
						/>
						<path
							class="slice slice-5"
							d="M50 50 L3.975 30.463 A50 50 0 0 1 50 0 Z"
						/>
						<g class="pie-separators">
							<line x1="50" y1="50" x2="50" y2="0" />
							<line x1="50" y1="50" x2="95.677" y2="29.663" />
							<line x1="50" y1="50" x2="86.568" y2="84.100" />
							<line x1="50" y1="50" x2="11.698" y2="82.139" />
							<line x1="50" y1="50" x2="3.975" y2="30.463" />
						</g>
						<circle class="pie-outline" cx="50" cy="50" r="49.2" />
					</svg>
				</span>
			</button>
		</span>
	{/each}
	{#if hasSource}
		<span class="original-separator" aria-hidden="true"></span>
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
    --ivory: #f7f6f0;
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
    border: 0;
    border-radius: 50%;
    background: transparent;
    color: #0b563f;
    cursor: pointer;
    isolation: isolate;
    -webkit-tap-highlight-color: transparent;
    transition:
      width 240ms cubic-bezier(0.2, 0.8, 0.2, 1),
      height 240ms cubic-bezier(0.2, 0.8, 0.2, 1),
      transform 170ms ease;
  }

  .depth-step::before {
    position: absolute;
    z-index: -2;
    inset: 0;
    border: 1px solid rgb(189 190 183 / 58%);
    border-radius: inherit;
    background: linear-gradient(145deg, #f1f0eb 0%, #ebeae4 78%, #e7e6e0 100%);
    box-shadow:
      0 5px 9px rgb(34 47 41 / 9%),
      0 2px 3px rgb(34 47 41 / 5%),
      inset 0 1px 1px rgb(255 255 255 / 96%),
      inset 0 -1px 2px rgb(165 163 156 / 17%);
    content: "";
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

  .depth-step.is-active::before {
    border-color: rgb(194 195 188 / 54%);
    background: linear-gradient(145deg, #f0efe9 0%, #ebeae4 72%, #e6e5df 100%);
    box-shadow:
      0 7px 12px rgb(31 46 39 / 11%),
      0 2px 4px rgb(31 46 39 / 5%),
      inset 0 1px 2px rgb(255 255 255 / 98%),
      inset 0 -2px 2px rgb(167 165 158 / 15%);
  }

  .depth-step.is-active .depth-step-core {
    width: 38px;
    height: 38px;
    border: 1px solid rgb(172 174 166 / 50%);
    background: linear-gradient(145deg, #f2f1ec 0%, #ebeae4 100%);
    box-shadow:
      0 1px 2px rgb(41 49 45 / 12%),
      inset 0 1px 1px rgb(255 255 255 / 90%),
      inset 0 -1px 2px rgb(157 158 151 / 11%);
  }

  .depth-pie {
    --s1: var(--ivory);
    --s2: var(--ivory);
    --s3: var(--ivory);
    --s4: var(--ivory);
    --s5: var(--ivory);
    display: block;
    width: 31px;
    height: 31px;
    overflow: hidden;
    border-radius: 50%;
    filter: drop-shadow(0 1px 0 rgb(255 255 255 / 72%));
  }

  .slice {
    stroke: none;
  }

  .slice-1 {
    fill: var(--s1);
  }

  .slice-2 {
    fill: var(--s2);
  }

  .slice-3 {
    fill: var(--s3);
  }

  .slice-4 {
    fill: var(--s4);
  }

  .slice-5 {
    fill: var(--s5);
  }

  .pie-separators line {
    stroke: #f8f7f2;
    stroke-width: 1.4;
    stroke-linecap: round;
    vector-effect: non-scaling-stroke;
  }

  .pie-outline {
    fill: none;
    stroke: rgb(134 139 131 / 16%);
    stroke-width: 0.8;
    vector-effect: non-scaling-stroke;
  }

  .depth-step-1 .depth-pie {
    --s1: #07533b;
    --s2: #f3f2ec;
    --s3: #f5f4ee;
    --s4: #dedfda;
    --s5: #f1f1ec;
  }

  .depth-step-2 .depth-pie {
    --s1: #07533b;
    --s2: #809b91;
    --s3: #f4f3ed;
    --s4: #dedfda;
    --s5: #f1f1ec;
  }

  .depth-step-3 .depth-pie {
    --s1: #07533b;
    --s2: #0c5942;
    --s3: #0a523c;
    --s4: #f3f2ec;
    --s5: #f6f5ef;
  }

  .depth-step-4 .depth-pie {
    --s1: #07533b;
    --s2: #0b5841;
    --s3: #0b543e;
    --s4: #155f49;
    --s5: #d9dad5;
  }

  .original-separator {
    width: 1px;
    height: 24px;
    flex: 0 0 1px;
    margin: 0 7px;
    background: linear-gradient(
      to bottom,
      transparent,
      rgb(117 120 113 / 22%) 18%,
      rgb(117 120 113 / 22%) 82%,
      transparent
    );
    box-shadow: 1px 0 rgb(255 255 255 / 68%);
  }

  .original-step-core {
    color: #0b563f;
  }

  .original-step.is-active .original-step-core {
    border-color: rgb(11 86 63 / 24%);
    background: linear-gradient(145deg, #f3f4ed 0%, #e7ede7 100%);
  }

  .original-icon {
    display: grid;
    width: 19px;
    height: 19px;
    place-items: center;
    filter: drop-shadow(0 1px 0 rgb(255 255 255 / 75%));
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

  .segmented-depth--showcase .depth-pie {
    width: 46px;
    height: 46px;
  }

  .segmented-depth--showcase .original-separator {
    height: 34px;
    margin: 0 11px;
  }

  .segmented-depth--showcase .original-icon {
    width: 27px;
    height: 27px;
  }

  .segmented-depth--showcase .original-step.is-active .original-icon {
    width: 31px;
    height: 31px;
  }

  .segmented-depth--showcase .pie-separators line {
    stroke-width: 2.1;
  }

  @media (hover: hover) {
    .depth-step:hover:not(.is-active) {
      transform: translateY(-2px);
    }
  }

  .depth-step:active {
    transform: translateY(1px) scale(0.985);
  }

  .depth-step:focus-visible {
    outline: 3px solid rgb(11 86 63 / 28%);
    outline-offset: 3px;
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

    .segmented-depth--compact .depth-pie {
      width: 26px;
      height: 26px;
    }

    .segmented-depth--compact .pie-separators line {
      stroke-width: 1.2;
    }

    .segmented-depth--compact .original-separator {
      height: 20px;
      margin: 0 4px;
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
