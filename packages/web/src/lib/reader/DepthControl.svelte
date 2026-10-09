<script lang="ts">
  import { libraryVariants, type LibraryVariant } from './reading-depth';

  let {
    variants,
    selected,
    onselect
  }: {
    variants: LibraryVariant[];
    selected: LibraryVariant;
    onselect: (variant: LibraryVariant) => void;
  } = $props();

  const variantNames: Record<LibraryVariant, string> = {
    concise: 'Concise',
    detailed: 'Detailed',
    source: 'Source'
  };
  const orderedVariants = $derived(libraryVariants.filter((variant) => variants.includes(variant)));
  const focusVariant = $derived(orderedVariants.includes(selected) ? selected : orderedVariants[0]);

  function moveSelection(event: KeyboardEvent): void {
    const keys = ['ArrowRight', 'ArrowDown', 'ArrowLeft', 'ArrowUp', 'Home', 'End'];
    if (!keys.includes(event.key)) return;
    const buttons = Array.from(
      (event.currentTarget as HTMLElement).querySelectorAll<HTMLButtonElement>('[role="radio"]')
    );
    const current = buttons.indexOf(event.target as HTMLButtonElement);
    if (current < 0) return;
    event.preventDefault();
    const forward = event.key === 'ArrowRight' || event.key === 'ArrowDown';
    const index =
      event.key === 'Home'
        ? 0
        : event.key === 'End'
          ? buttons.length - 1
          : (current + (forward ? 1 : -1) + buttons.length) % buttons.length;
    buttons[index].focus();
    buttons[index].click();
  }
</script>

{#if orderedVariants.length > 0}
  <div class="depth-chips" role="radiogroup" aria-label="Reading version" tabindex="-1" onkeydown={moveSelection}>
    {#each orderedVariants as variant (variant)}
      <button
        type="button"
        class="depth-chip"
        role="radio"
        aria-checked={selected === variant}
        tabindex={variant === focusVariant ? 0 : -1}
        onclick={() => onselect(variant)}
      >
        <span>{variantNames[variant]}</span>
      </button>
    {/each}
  </div>
{/if}

<style>
  .depth-chips {
    display: flex;
    min-width: 0;
    align-items: center;
    gap: 4px;
  }

  /* The visible chip is 36px tall; vertical padding extends the hit area to 44px. */
  .depth-chip {
    display: grid;
    min-width: 44px;
    padding: 4px 0;
    color: var(--foreground);
    font-size: 15px;
    font-weight: 650;
    line-height: 1;
    cursor: pointer;
    -webkit-tap-highlight-color: transparent;
  }

  .depth-chip span {
    display: grid;
    height: 36px;
    padding: 0 14px;
    place-items: center;
    background: var(--chip-frost, color-mix(in srgb, var(--foreground) 6%, transparent));
    -webkit-backdrop-filter: blur(18px) saturate(1.3);
    backdrop-filter: blur(18px) saturate(1.3);
    white-space: nowrap;
    transition: background 180ms ease, color 180ms ease;
  }

  .depth-chip[aria-checked='true'] span {
    background: var(--foreground);
    color: var(--background);
  }

  @media (hover: hover) {
    .depth-chip[aria-checked='false']:hover span {
      background: color-mix(in srgb, var(--foreground) 12%, transparent);
    }
  }

  .depth-chip:focus-visible {
    outline: none;
  }

  .depth-chip:focus-visible span {
    outline: 2px solid var(--ring);
    outline-offset: 2px;
  }

  @media (prefers-reduced-motion: reduce) {
    .depth-chip span {
      transition: none;
    }
  }
</style>
