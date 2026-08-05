<script lang="ts">
  import {
    isReadingDepth,
    readingDepths,
    sourceVariant,
    type LibraryVariant
  } from './reading-depth';

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

  const variantOrder = readingDepths;
  const summaryVariants = $derived(variants.filter(isReadingDepth));
  const hasSource = $derived(variants.includes(sourceVariant));
  const depthIconPaths = [
    'M4 9h16v2H4V9zm0 4h10v2H4v-2z',
    'M3 18h12v-2H3v2zm0-12v2h18V6H3zm0 7h18v-2H3v2z'
  ];
  const variantNames: Record<LibraryVariant, string> = {
    concise: 'Concise',
    detailed: 'Detailed',
    source: 'Original'
  };
</script>

{#if summaryVariants.length > 0}
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
          class:is-active={selected === sourceVariant}
          role="radio"
          aria-checked={selected === sourceVariant}
          aria-label={variantNames.source}
          title={variantNames.source}
          onclick={() => onselect(sourceVariant)}
        >
          <span class="depth-step-core original-step-core">
            <svg class="original-icon" viewBox="0 0 24 24" aria-hidden="true">
              <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" fill="none" />
              <path d="M14 2v6h6M16 13H8M16 17H8M10 9H8" fill="none" />
            </svg>
          </span>
        </button>
      </span>
    {/if}
  </div>
{/if}

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
    color: var(--popover-foreground);
    cursor: pointer;
    -webkit-tap-highlight-color: transparent;
    transition: background 160ms ease, color 160ms ease;
  }
  .depth-step-core {
    display: grid;
    width: 38px;
    height: 38px;
    place-items: center;
    border-radius: inherit;
  }
  .depth-step.is-active {
    background: var(--primary);
    color: var(--primary-foreground);
  }
  .depth-icon {
    display: block;
    width: 21px;
    height: 21px;
    fill: currentColor;
  }
  .original-icon {
    width: 19px;
    height: 19px;
    fill: none;
    stroke: currentColor;
    stroke-linecap: round;
    stroke-linejoin: round;
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
      background: var(--accent);
      color: var(--accent-foreground);
    }
  }
  .depth-step:active:not(.is-active) {
    background: var(--secondary);
    color: var(--secondary-foreground);
  }
  .depth-step:focus-visible {
    outline: 2px solid var(--ring);
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
    .segmented-depth--compact .depth-step-core,
    .segmented-depth--compact .depth-step.is-active,
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
  :global(.native-reader-footer) .segmented-depth--compact {
    height: 44px;
    gap: 0;
    padding: 0;
  }
  :global(.native-reader-footer) .segmented-depth--compact .depth-slot,
  :global(.native-reader-footer) .segmented-depth--compact .depth-step,
  :global(.native-reader-footer) .segmented-depth--compact .depth-step-core {
    width: 44px;
    height: 44px;
    flex-basis: 44px;
    border-radius: 0;
  }
  :global(.native-reader-footer) .segmented-depth--compact .depth-step.is-active {
    background: var(--accent);
    box-shadow: none;
    color: var(--accent-foreground);
  }
  :global(.native-reader-footer) .segmented-depth--compact .depth-step:focus-visible {
    outline: 0;
    box-shadow: inset 0 0 0 2px var(--ring);
  }
  @media (prefers-reduced-motion: reduce) {
    .depth-step,
    .depth-step-core {
      transition-duration: 0.01ms;
    }
  }
</style>
