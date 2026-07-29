<script module lang="ts">
  let activeAudio: HTMLAudioElement | null = null;
</script>

<script lang="ts">
  import { onDestroy } from 'svelte';

  let {
    src,
    title,
    volume = $bindable(1),
    playing = $bindable(false),
    showVolume = true,
    presentation = 'standard'
  }: {
    src: string;
    title: string;
    volume?: number;
    playing?: boolean;
    showVolume?: boolean;
    presentation?: 'standard' | 'apple';
  } = $props();
  let audio: HTMLAudioElement;
  let currentTime = $state(0);
  let duration = $state(0);
  let rate = $state(1);
  let error = $state('');
  let played = $derived(duration ? (currentTime / duration) * 100 : 0);

  function positionKey(): string {
    return `briefly:audio-position:${src}`;
  }

  function rememberPosition(): void {
    if (audio.currentTime > 0 && audio.currentTime < audio.duration) {
      localStorage.setItem(positionKey(), String(audio.currentTime));
    }
  }

  function syncTime(): void {
    currentTime = audio.currentTime;
    duration = Number.isFinite(audio.duration) ? audio.duration : 0;
    rememberPosition();
  }

  function restorePosition(): void {
    duration = Number.isFinite(audio.duration) ? audio.duration : 0;
    const saved = Number(localStorage.getItem(positionKey()));
    if (saved > 0 && saved < duration) audio.currentTime = saved;
    syncTime();
  }

  async function toggle(): Promise<void> {
    error = '';
    if (!audio.paused) {
      audio.pause();
      return;
    }
    try {
      await audio.play();
    } catch {
      error = 'Audio could not be played.';
    }
  }

  function skip(seconds: number): void {
    audio.currentTime = Math.max(0, Math.min(duration, audio.currentTime + seconds));
    syncTime();
  }

  function seek(event: Event): void {
    audio.currentTime = Number((event.currentTarget as HTMLInputElement).value);
    syncTime();
  }

  function setVolume(event: Event): void {
    volume = Number((event.currentTarget as HTMLInputElement).value);
    audio.volume = volume;
  }

  function cycleRate(): void {
    const rates = [1, 1.25, 1.5, 1.75, 2];
    rate = rates[(rates.indexOf(rate) + 1) % rates.length];
    audio.playbackRate = rate;
  }

  function onPlay(): void {
    if (activeAudio && activeAudio !== audio) activeAudio.pause();
    activeAudio = audio;
    playing = true;
    if ('mediaSession' in navigator) {
      navigator.mediaSession.metadata = new MediaMetadata({
        title,
        artist: 'Briefly'
      });
      navigator.mediaSession.playbackState = 'playing';
    }
  }

  function onPause(): void {
    playing = false;
    rememberPosition();
    if ('mediaSession' in navigator && activeAudio === audio) {
      navigator.mediaSession.playbackState = 'paused';
    }
  }

  function onEnded(): void {
    localStorage.removeItem(positionKey());
    onPause();
  }

  function formatTime(seconds: number): string {
    if (!Number.isFinite(seconds)) return '–:––';
    const whole = Math.max(0, Math.floor(seconds));
    const hours = Math.floor(whole / 3600);
    const minutes = Math.floor((whole % 3600) / 60);
    const clock = `${minutes}:${String(whole % 60).padStart(2, '0')}`;
    return hours ? `${hours}:${clock.padStart(5, '0')}` : clock;
  }

  $effect(() => {
    if (audio) audio.volume = volume;
  });

  onDestroy(() => {
    if (activeAudio === audio) activeAudio = null;
    rememberPosition();
    audio?.pause();
  });
</script>

<div
  class="audio-player border-border! bg-muted! bg-none! text-foreground! rounded-xl! border shadow-sm!"
  class:apple={presentation === 'apple'}
  role="group"
  aria-label={`${title} audio player`}
>
  <audio
    bind:this={audio}
    {src}
    preload="metadata"
    onloadedmetadata={restorePosition}
    ondurationchange={syncTime}
    ontimeupdate={syncTime}
    onplay={onPlay}
    onpause={onPause}
    onended={onEnded}
    onerror={() => (error = 'Audio could not be loaded.')}
  ></audio>

  {#if presentation === 'apple'}
    <div class="apple-timeline">
      <input
        aria-label="Seek"
        type="range"
        min="0"
        max={duration}
        step="0.1"
        value={currentTime}
        disabled={!duration}
        style={`--played: ${played}%`}
        oninput={seek}
      />
      <div class="apple-times">
        <span>{formatTime(currentTime)}</span>
        <span>−{duration ? formatTime(duration - currentTime) : '–:––'}</span>
      </div>
    </div>

    <div class="apple-controls">
      <button class="apple-rate" aria-label="Change playback speed" title="Playback speed" onclick={cycleRate}>
        {rate}×
      </button>
      <button aria-label="Back 15 seconds" title="Back 15 seconds" onclick={() => skip(-15)}>
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <path d="M12 4V1L8 5l4 4V6a7 7 0 1 1-6.4 4.2" />
          <text x="12" y="16" text-anchor="middle">15</text>
        </svg>
      </button>
      <button class="apple-play" class:playing aria-label={playing ? 'Pause' : 'Play'} onclick={toggle}>
        <svg viewBox="0 0 24 24" aria-hidden="true">
          {#if playing}
            <path d="M8 4v16M16 4v16" />
          {:else}
            <path d="m7 3 14 9-14 9Z" />
          {/if}
        </svg>
      </button>
      <button aria-label="Forward 30 seconds" title="Forward 30 seconds" onclick={() => skip(30)}>
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <path d="M12 4V1l4 4-4 4V6a7 7 0 1 0 6.4 4.2" />
          <text x="12" y="16" text-anchor="middle">30</text>
        </svg>
      </button>
      <button aria-label="Sleep timer unavailable" title="Sleep timer" disabled>
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <path d="M15.5 3.5a7.5 7.5 0 1 0 5 12 8 8 0 0 1-5-12Z" />
          <text x="18" y="7" text-anchor="middle">z</text>
          <text x="21" y="4" text-anchor="middle">z</text>
        </svg>
      </button>
    </div>
  {:else}
    <div class="transport">
      <button aria-label="Back 15 seconds" title="Back 15 seconds" onclick={() => skip(-15)}>−15</button>
      <button class="play bg-primary! text-primary-foreground!" aria-label={playing ? 'Pause' : 'Play'} onclick={toggle}>
        <svg viewBox="0 0 24 24" aria-hidden="true">
          {#if playing}
            <path d="M8 5v14M16 5v14" />
          {:else}
            <path d="m8 5 11 7-11 7Z" />
          {/if}
        </svg>
      </button>
      <button aria-label="Forward 15 seconds" title="Forward 15 seconds" onclick={() => skip(15)}>+15</button>
    </div>

    <div class="timeline">
      <span>{formatTime(currentTime)}</span>
      <input
        aria-label="Seek"
        type="range"
        min="0"
        max={duration}
        step="0.1"
        value={currentTime}
        disabled={!duration}
        style={`--played: ${played}%`}
        oninput={seek}
      />
      <span>{duration ? formatTime(duration) : '–:––'}</span>
    </div>

    <button class="rate border-border! bg-secondary! text-secondary-foreground!" aria-label="Change playback speed" title="Playback speed" onclick={cycleRate}>
      {rate}×
    </button>

    {#if showVolume}
      <label class="volume text-muted-foreground!">
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <path d="M11 5 6 9H2v6h4l5 4ZM15 9a4 4 0 0 1 0 6M18 6a8 8 0 0 1 0 12" />
        </svg>
        <input
          aria-label="Volume"
          type="range"
          min="0"
          max="1"
          step="0.05"
          value={volume}
          style={`--played: ${volume * 100}%`}
          oninput={setVolume}
        />
      </label>
    {/if}
  {/if}

  {#if error}<span class="error text-destructive!" role="alert">{error}</span>{/if}
</div>

<style>
  audio {
    display: none;
  }

  .audio-player {
    display: grid;
    grid-template-columns: auto minmax(150px, 1fr) auto auto;
    align-items: center;
    gap: 12px;
    width: 100%;
    padding: 10px 12px;
    font-family: var(--theme-font-sans);
  }

  .audio-player.apple {
    grid-template-columns: minmax(0, 1fr);
    grid-template-rows: auto 1fr;
    gap: 10px;
    padding: 10px 14px;
  }

  .apple-timeline {
    display: grid;
    min-width: 0;
    gap: 7px;
  }

  .apple-timeline input {
    width: 100%;
  }

  .apple-times {
    display: flex;
    justify-content: space-between;
    color: var(--muted-foreground);
    font-size: 11px;
    font-variant-numeric: tabular-nums;
  }

  .apple-controls {
    display: grid;
    grid-template-columns: repeat(5, minmax(0, 1fr));
    align-items: center;
  }

  .apple-controls button {
    width: 42px;
    height: 42px;
    min-width: 0;
    justify-self: center;
    color: var(--foreground);
  }

  .apple-controls svg {
    width: 34px;
    height: 34px;
    stroke-width: 2.2;
  }

  .apple-controls text {
    fill: currentColor;
    stroke: none;
    font-size: 6px;
    font-weight: 700;
  }

  .apple-controls .apple-rate {
    color: var(--muted-foreground);
    font-size: 16px;
    font-variant-numeric: tabular-nums;
  }

  .apple-controls .apple-play {
    width: 58px;
    height: 58px;
  }

  .apple-play svg {
    width: 44px;
    height: 44px;
    fill: currentColor;
    stroke: none;
  }

  .apple-play.playing svg {
    fill: none;
    stroke: currentColor;
  }

  .transport,
  .timeline,
  .volume {
    display: flex;
    align-items: center;
  }

  .transport {
    gap: 4px;
  }

  button {
    display: grid;
    place-items: center;
    min-width: 34px;
    height: 34px;
    border-radius: 999px;
    font-size: 11px;
    font-weight: 700;
  }

  button:hover {
    filter: brightness(0.96);
  }

  button:focus-visible {
    outline: 2px solid var(--ring);
    outline-offset: 2px;
  }

  .play {
    width: 38px;
    height: 38px;
  }

  svg {
    fill: none;
    stroke: currentColor;
    stroke-linecap: round;
    stroke-linejoin: round;
    stroke-width: 2;
  }

  .play :global(svg) {
    width: 17px;
    height: 17px;
  }

  .timeline {
    min-width: 0;
    gap: 9px;
  }

  .timeline span {
    width: 42px;
    color: var(--muted-foreground);
    font-size: 11px;
    font-variant-numeric: tabular-nums;
  }

  .timeline span:last-child {
    text-align: right;
  }

  input[type="range"] {
    height: 4px;
    margin: 0;
    border-radius: 999px;
    outline: 0;
    background: linear-gradient(
      to right,
      var(--primary) var(--played, 0%),
      color-mix(in srgb, var(--foreground) 18%, transparent) var(--played, 0%)
    );
    cursor: pointer;
    appearance: none;
  }

  input[type="range"]::-webkit-slider-thumb {
    width: 13px;
    height: 13px;
    border: 2px solid var(--card);
    border-radius: 50%;
    background: var(--primary);
    box-shadow: 0 1px 3px color-mix(in srgb, var(--foreground) 20%, transparent);
    appearance: none;
  }

  input[type="range"]:focus-visible {
    outline: 2px solid var(--ring);
    outline-offset: 3px;
  }

  .timeline input {
    min-width: 0;
    flex: 1;
  }

  .rate {
    padding: 0 9px;
    border: 1px solid var(--border);
    border-radius: 8px;
    font-variant-numeric: tabular-nums;
  }

  .volume {
    gap: 7px;
  }

  .volume :global(svg) {
    width: 16px;
    height: 16px;
  }

  .volume input {
    width: 70px;
  }

  .error {
    grid-column: 1 / -1;
    font-size: 12px;
  }

  @media (max-width: 700px) {
    .audio-player:not(.apple) {
      grid-template-columns: auto minmax(100px, 1fr) auto;
    }

    .volume {
      display: none;
    }
  }
</style>
