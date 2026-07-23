import type { LibraryEntry, LibraryVariant } from '$lib/library.js';
import { preferredVariant, textFor } from '$lib/library.js';

export type SpeechState = 'idle' | 'playing' | 'paused';

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

function speechChunks(text: string, maximumLength = 1200): string[] {
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
	currentEntry = $state<LibraryEntry | null>(null);
	currentVariant = $state<LibraryVariant>('concise');
	rate = $state(1);
	progress = $state(0);
	queue = $state<LibraryEntry[]>([]);

	private chunks: string[] = [];
	private chunkIndex = 0;

	play(entry: LibraryEntry, variant: LibraryVariant): void {
		if (!('speechSynthesis' in globalThis)) return;
		const availableVariant = textFor(entry, variant) ? variant : preferredVariant(entry);
		const text = textFor(entry, availableVariant)?.text ?? '';
		if (!text.trim()) return;

		speechSynthesis.cancel();
		this.currentEntry = entry;
		this.currentVariant = availableVariant;
		this.chunks = speechChunks(spokenText(text));
		this.chunkIndex = 0;
		this.progress = 0;
		this.state = 'playing';
		this.updateMediaSession();
		this.speakNextChunk();
	}

	toggle(): void {
		if (!('speechSynthesis' in globalThis) || !this.currentEntry) return;
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
		if ('speechSynthesis' in globalThis) speechSynthesis.cancel();
		this.state = 'idle';
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
		if (this.state === 'playing' && this.currentEntry) {
			this.play(this.currentEntry, this.currentVariant);
		}
	}

	dispose(): void {
		this.stop();
	}

	private speakNextChunk(): void {
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
			if (this.state !== 'playing') return;
			this.chunkIndex += 1;
			this.progress = Math.min(1, this.chunkIndex / Math.max(1, this.chunks.length));
			this.speakNextChunk();
		};
		utterance.onerror = () => {
			this.state = 'idle';
		};
		speechSynthesis.speak(utterance);
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
		navigator.mediaSession.playbackState = 'playing';
		navigator.mediaSession.setActionHandler('play', () => this.toggle());
		navigator.mediaSession.setActionHandler('pause', () => this.toggle());
		navigator.mediaSession.setActionHandler('stop', () => this.stop());
		navigator.mediaSession.setActionHandler('nexttrack', () => this.playNext());
	}
}
