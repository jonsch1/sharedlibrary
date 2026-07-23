import type { LibraryEntry, LibraryVariant } from '$lib/library.js';
import { preferredVariant, textFor } from '$lib/library.js';
import {
	createOpenRouterSpeechSource,
	openRouterSpeechChunks,
	OpenRouterSpeechError,
	type OpenRouterCredential,
	type OpenRouterSpeechSource,
	type OpenRouterVoice
} from '$lib/openrouter.js';

export type SpeechState = 'idle' | 'loading' | 'playing' | 'paused';
export type SpeechProvider = 'openrouter' | 'device' | null;

function isAppleMobileBrowser(): boolean {
	if (!('navigator' in globalThis)) return false;
	return (
		/iPad|iPhone|iPod/.test(navigator.userAgent) ||
		(navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)
	);
}

function spokenText(markdown: string): string {
	return markdown
		.replace(/^---[\s\S]*?---\s*/m, '')
		.replace(/```[\s\S]*?```/g, ' ')
		.replace(/`([^`]+)`/g, '$1')
		.replace(/!\[[^\]]*\]\([^)]+\)/g, ' ')
		.replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
		.replace(/^#{1,6}\s+/gm, '')
		.replace(/^>\s?/gm, '')
		.replace(/^[*-]\s+/gm, '')
		.replace(/^\d+\.\s+/gm, '')
		.replace(/[*_~]/g, '')
		.replace(/\s+/g, ' ')
		.trim();
}

function deviceSpeechChunks(text: string, maximumLength = 1200): string[] {
	const sentences = text.match(/[^.!?]+[.!?]+|[^.!?]+$/g) ?? [text];
	const chunks: string[] = [];
	let current = '';
	for (const sentence of sentences) {
		const trimmed = sentence.trim();
		if (!trimmed) continue;
		if (current && current.length + trimmed.length + 1 > maximumLength) {
			chunks.push(current);
			current = trimmed;
		} else {
			current = current ? `${current} ${trimmed}` : trimmed;
		}
	}
	if (current) chunks.push(current);
	return chunks;
}

export class SpeechPlayer {
	state = $state<SpeechState>('idle');
	provider = $state<SpeechProvider>(null);
	currentEntry = $state<LibraryEntry | null>(null);
	currentVariant = $state<LibraryVariant>('concise');
	rate = $state(1);
	progress = $state(0);
	queue = $state<LibraryEntry[]>([]);
	notice = $state('');
	requiresReconnect = $state(false);

	private credential: OpenRouterCredential | null = null;
	private voice: OpenRouterVoice = 'eve';
	private chunks: string[] = [];
	private chunkIndex = 0;
	private audio: HTMLAudioElement | null = null;
	private attachedAudio: HTMLAudioElement | null = null;
	private releaseAudioSource: (() => void) | null = null;
	private abortController: AbortController | null = null;
	private sourcePromises = new Map<number, Promise<OpenRouterSpeechSource>>();
	private playbackWatchdog: number | null = null;
	private sessionID = 0;

	configureOpenRouter(
		credential: OpenRouterCredential | null,
		voice: OpenRouterVoice
	): void {
		this.credential = credential;
		this.voice = voice;
		this.requiresReconnect = false;
	}

	attachAudioElement(audio: HTMLAudioElement): void {
		if (this.attachedAudio === audio) return;
		if (this.audio && this.audio !== audio) this.releaseAudio();
		this.attachedAudio = audio;
	}

	play(entry: LibraryEntry, variant: LibraryVariant): void {
		const availableVariant = textFor(entry, variant) ? variant : preferredVariant(entry);
		const text = textFor(entry, availableVariant)?.text ?? '';
		const cleanText = spokenText(text);
		if (!cleanText) return;

		this.cancelActivePlayback();
		const sessionID = ++this.sessionID;
		this.currentEntry = entry;
		this.currentVariant = availableVariant;
		this.chunkIndex = 0;
		this.progress = 0;
		this.notice = '';
		this.requiresReconnect = false;
		this.updateMediaSession();

		if (this.credential) {
			this.provider = 'openrouter';
			this.chunks = openRouterSpeechChunks(cleanText);
			this.state = 'loading';
			this.abortController = new AbortController();
			void this.playOpenRouterChunk(sessionID);
			return;
		}
		this.startDeviceSpeech(cleanText);
	}

	toggle(): void {
		if (!this.currentEntry) return;
		if (this.state === 'loading') {
			this.stop();
			return;
		}

		if (this.provider === 'openrouter' && this.audio) {
			if (this.state === 'playing') {
				this.clearPlaybackWatchdog();
				this.audio.pause();
				this.state = 'paused';
				if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'paused';
			} else {
				const audio = this.audio;
				const sessionID = this.sessionID;
				void this.audio
					.play()
					.then(() => {
						this.markAudioPlaying(audio, sessionID);
					})
					.catch(() => {
						this.state = 'paused';
						this.notice = 'Audio is ready. Tap Play to begin.';
					});
			}
			return;
		}

		if (!('speechSynthesis' in globalThis)) return;
		if (this.state === 'playing') {
			speechSynthesis.pause();
			this.state = 'paused';
			if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'paused';
		} else if (this.state === 'paused') {
			speechSynthesis.resume();
			this.state = 'playing';
			if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'playing';
		} else {
			this.play(this.currentEntry, this.currentVariant);
		}
	}

	stop(): void {
		++this.sessionID;
		this.cancelActivePlayback();
		this.state = 'idle';
		this.provider = null;
		this.progress = 0;
		this.chunks = [];
		this.chunkIndex = 0;
		if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'none';
	}

	enqueue(entry: LibraryEntry): void {
		if (this.currentEntry?.id === entry.id || this.queue.some((item) => item.id === entry.id)) {
			return;
		}
		this.queue = [...this.queue, entry];
	}

	removeFromQueue(entryID: string): void {
		this.queue = this.queue.filter((entry) => entry.id !== entryID);
	}

	playNext(): void {
		const [next, ...remaining] = this.queue;
		if (!next) {
			this.stop();
			return;
		}
		this.queue = remaining;
		this.play(next, preferredVariant(next));
	}

	setRate(rate: number): void {
		this.rate = rate;
		if (this.audio) {
			this.audio.playbackRate = rate;
		} else if (this.provider === 'device' && this.state === 'playing' && this.currentEntry) {
			this.play(this.currentEntry, this.currentVariant);
		}
	}

	dispose(): void {
		this.stop();
	}

	private async playOpenRouterChunk(sessionID: number): Promise<void> {
		const chunk = this.chunks[this.chunkIndex];
		if (!chunk) {
			this.progress = 1;
			this.playNext();
			return;
		}
		if (!this.credential) {
			this.fallbackToDevice(chunk, 'OpenRouter was disconnected. Using the device voice.');
			return;
		}

		this.state = 'loading';
		let failureHandled = false;
		const fail = (message: string, status?: number): void => {
			if (failureHandled || sessionID !== this.sessionID) return;
			failureHandled = true;
			if (status === 401 || status === 403) this.requiresReconnect = true;
			this.fallbackToDevice(chunk, `${message} Using the device voice.`);
		};
		try {
			const source = await this.sourceForChunk(this.chunkIndex, sessionID);
			this.sourcePromises.delete(this.chunkIndex);
			if (sessionID !== this.sessionID) {
				source.release();
				return;
			}
			this.releaseCurrentAudioSource();
			this.releaseAudioSource = source.release;
			const audio = this.audio ?? this.attachedAudio ?? new Audio();
			audio.src = source.url;
			audio.preload = 'auto';
			audio.playbackRate = this.rate;
			this.audio = audio;
			const nextChunkIndex = this.chunkIndex + 1;
			if (nextChunkIndex < this.chunks.length) {
				void this.sourceForChunk(nextChunkIndex, sessionID).catch(() => {
					// The error is handled if this segment is needed for playback.
				});
			}
			audio.ontimeupdate = () => {
				if (sessionID !== this.sessionID) return;
				if (audio.currentTime > 0.1) this.clearPlaybackWatchdog();
				const withinChunk =
					Number.isFinite(audio.duration) && audio.duration > 0
						? audio.currentTime / audio.duration
						: 0;
				this.progress = Math.min(
					1,
					(this.chunkIndex + withinChunk) / Math.max(1, this.chunks.length)
				);
			};
			audio.onended = () => {
				if (sessionID !== this.sessionID) return;
				this.releaseCurrentAudioSource();
				this.chunkIndex += 1;
				this.progress = Math.min(1, this.chunkIndex / Math.max(1, this.chunks.length));
				void this.playOpenRouterChunk(sessionID);
			};
			audio.onerror = () => {
				fail('The generated audio could not be played.');
			};
			audio.onplaying = () => {
				this.markAudioPlaying(audio, sessionID);
			};
			if (this.chunkIndex === 0 && isAppleMobileBrowser()) {
				this.state = 'paused';
				this.notice = 'Audio is ready. Tap Play to begin.';
				if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'paused';
				return;
			}
			await audio.play();
			this.markAudioPlaying(audio, sessionID);
		} catch (error) {
			if (sessionID !== this.sessionID || (error instanceof DOMException && error.name === 'AbortError')) {
				return;
			}
			if (error instanceof DOMException && error.name === 'NotAllowedError' && this.audio) {
				this.state = 'paused';
				this.notice = 'Audio is ready. Tap play to begin.';
				return;
			}
			if (failureHandled) return;
			if (error instanceof OpenRouterSpeechError) {
				fail(error.message, error.status);
				return;
			}
			const message = error instanceof Error ? error.message : 'OpenRouter speech is unavailable.';
			fail(message);
		}
	}

	private fallbackToDevice(remainingChunk: string, notice: string): void {
		const remainingText = [remainingChunk, ...this.chunks.slice(this.chunkIndex + 1)].join(' ');
		this.cancelActivePlayback();
		this.notice = notice;
		this.startDeviceSpeech(remainingText);
	}

	private sourceForChunk(
		index: number,
		sessionID: number
	): Promise<OpenRouterSpeechSource> {
		const existing = this.sourcePromises.get(index);
		if (existing) return existing;

		const chunk = this.chunks[index];
		const credential = this.credential;
		const controller = this.abortController;
		if (!chunk || !credential || !controller) {
			return Promise.reject(new DOMException('Speech generation was cancelled.', 'AbortError'));
		}

		const sourcePromise = createOpenRouterSpeechSource(
			credential,
			chunk,
			this.voice,
			controller.signal
		).then((source) => {
			if (sessionID !== this.sessionID || controller.signal.aborted) {
				source.release();
				throw new DOMException('Speech generation was cancelled.', 'AbortError');
			}
			return source;
		});
		this.sourcePromises.set(index, sourcePromise);
		return sourcePromise;
	}

	private startDeviceSpeech(text: string): void {
		if (!('speechSynthesis' in globalThis)) {
			this.state = 'idle';
			this.provider = null;
			this.notice = 'Speech playback is unavailable in this browser.';
			return;
		}
		this.provider = 'device';
		this.chunks = deviceSpeechChunks(text);
		this.chunkIndex = 0;
		this.progress = 0;
		this.state = 'playing';
		this.updateMediaSession();
		this.speakNextDeviceChunk();
	}

	private speakNextDeviceChunk(): void {
		if (!('speechSynthesis' in globalThis) || this.state !== 'playing') return;
		const chunk = this.chunks[this.chunkIndex];
		if (!chunk) {
			this.progress = 1;
			this.playNext();
			return;
		}

		const utterance = new SpeechSynthesisUtterance(chunk);
		utterance.rate = this.rate;
		utterance.onend = () => {
			if (this.state !== 'playing' || this.provider !== 'device') return;
			this.chunkIndex += 1;
			this.progress = Math.min(1, this.chunkIndex / Math.max(1, this.chunks.length));
			this.speakNextDeviceChunk();
		};
		utterance.onerror = () => {
			this.state = 'idle';
		};
		speechSynthesis.speak(utterance);
	}

	private cancelActivePlayback(): void {
		if ('speechSynthesis' in globalThis) speechSynthesis.cancel();
		this.clearPlaybackWatchdog();
		this.abortController?.abort();
		this.abortController = null;
		const pendingSources = [...this.sourcePromises.values()];
		this.sourcePromises.clear();
		for (const sourcePromise of pendingSources) {
			void sourcePromise.then((source) => source.release()).catch(() => {});
		}
		this.releaseAudio();
	}

	private releaseAudio(): void {
		if (this.audio) {
			this.audio.ontimeupdate = null;
			this.audio.onended = null;
			this.audio.onerror = null;
			this.audio.onplaying = null;
			this.audio.pause();
			this.audio.removeAttribute('src');
			this.audio.load();
			this.audio = null;
		}
		this.releaseCurrentAudioSource();
	}

	private releaseCurrentAudioSource(): void {
		this.releaseAudioSource?.();
		this.releaseAudioSource = null;
	}

	private markAudioPlaying(audio: HTMLAudioElement, sessionID: number): void {
		if (sessionID !== this.sessionID || this.audio !== audio) return;
		this.state = 'playing';
		this.notice = '';
		if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'playing';
		this.monitorPlayback(audio, sessionID);
	}

	private monitorPlayback(audio: HTMLAudioElement, sessionID: number): void {
		this.clearPlaybackWatchdog();
		const startingTime = audio.currentTime;
		this.playbackWatchdog = window.setTimeout(() => {
			this.playbackWatchdog = null;
			if (
				sessionID !== this.sessionID ||
				this.audio !== audio ||
				this.state !== 'playing' ||
				audio.currentTime > startingTime + 0.05
			) {
				return;
			}
			audio.pause();
			this.state = 'paused';
			this.notice =
				'Playback was blocked by iOS. Open Shared Library in Safari instead of as an installed web app.';
			if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'paused';
		}, 2_500);
	}

	private clearPlaybackWatchdog(): void {
		if (this.playbackWatchdog === null) return;
		window.clearTimeout(this.playbackWatchdog);
		this.playbackWatchdog = null;
	}

	private updateMediaSession(): void {
		if (!('mediaSession' in navigator) || !this.currentEntry) return;
		navigator.mediaSession.metadata = new MediaMetadata({
			title: this.currentEntry.title,
			artist:
				this.currentEntry.origin === 'shared'
					? `Shared by ${this.currentEntry.sharedByDisplayName ?? 'a collaborator'}`
					: 'Shared Library',
			album: this.currentVariant === 'source' ? 'Original' : `${this.currentVariant} summary`
		});
		navigator.mediaSession.playbackState = this.state === 'paused' ? 'paused' : 'playing';
		navigator.mediaSession.setActionHandler('play', () => this.toggle());
		navigator.mediaSession.setActionHandler('pause', () => this.toggle());
		navigator.mediaSession.setActionHandler('stop', () => this.stop());
		navigator.mediaSession.setActionHandler('nexttrack', () => this.playNext());
	}
}
