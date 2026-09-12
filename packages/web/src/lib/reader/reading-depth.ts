export const readingDepths = ['concise', 'detailed'] as const;

export type ReadingDepth = (typeof readingDepths)[number];

export const sourceVariant = 'source' as const;

export const libraryVariants = [...readingDepths, sourceVariant] as const;

export type LibraryVariant = (typeof libraryVariants)[number];

export function isReadingDepth(value: unknown): value is ReadingDepth {
  return typeof value === 'string' && readingDepths.includes(value as ReadingDepth);
}
