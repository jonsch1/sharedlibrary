export function sourceTextParagraphs(text: string): string[] {
	const paragraphs: string[] = [];
	let current: string[] = [];

	const flush = (): void => {
		const paragraph = current.join(' ').replace(/[ \t]+/g, ' ').trim();
		if (paragraph) paragraphs.push(paragraph);
		current = [];
	};

	for (const rawLine of text.replace(/\r\n?/g, '\n').split('\n')) {
		let line = rawLine.trim();
		if (!line) {
			flush();
			continue;
		}

		const speakerTurn = /^>{2,}\s*(.*)$/.exec(line);
		if (speakerTurn) {
			flush();
			line = speakerTurn[1].trim();
			if (!line) continue;
		}

		current.push(line);
	}

	flush();
	return paragraphs;
}
