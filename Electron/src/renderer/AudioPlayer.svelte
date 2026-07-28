<script module lang="ts">
  let activeAudio: HTMLAudioElement | null = null;
</script>

<script lang="ts">
  import { Pause, Play, Volume2 } from '@lucide/svelte';
  import { onDestroy } from 'svelte';

  let { src, title }: { src: string; title: string } = $props();
  let audio: HTMLAudioElement;
  let currentTime = $state(0);
  let duration = $state(0);
  let playing = $state(false);
  let volume = $state(1);
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
    return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, '0')}`;
  }

  onDestroy(() => {
    if (activeAudio === audio) activeAudio = null;
    rememberPosition();
    audio?.pause();
  });
</script>

<div
  class="audio-player border-border! bg-muted! bg-none! text-foreground! rounded-xl! border shadow-sm!"
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

  <div class="transport">
    <button aria-label="Back 15 seconds" title="Back 15 seconds" onclick={() => skip(-15)}>−15</button>
    <button class="play bg-primary! text-primary-foreground!" aria-label={playing ? 'Pause' : 'Play'} onclick={toggle}>
      {#if playing}<Pause />{:else}<Play />{/if}
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

  <label class="volume text-muted-foreground!">
    <Volume2 />
    <span class="sr-only">Volume</span>
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
    box-shadow: 0 1px 3px rgb(0 0 0 / 20%);
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
    .audio-player {
      grid-template-columns: auto minmax(100px, 1fr) auto;
    }

    .volume {
      display: none;
    }
  }
</style>
