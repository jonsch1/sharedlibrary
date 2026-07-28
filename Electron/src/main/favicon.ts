export function faviconExtension(
  bytes: Uint8Array
): 'gif' | 'ico' | 'jpg' | 'png' | 'webp' | undefined {
  const startsWith = (...values: number[]) =>
    values.every((value, index) => bytes[index] === value);
  if (startsWith(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)) return 'png';
  if (startsWith(0x00, 0x00, 0x01, 0x00)) return 'ico';
  if (startsWith(0xff, 0xd8, 0xff)) return 'jpg';
  const header = new TextDecoder('ascii').decode(bytes.subarray(0, 12));
  if (header.startsWith('GIF87a') || header.startsWith('GIF89a')) return 'gif';
  if (header.startsWith('RIFF') && header.endsWith('WEBP')) return 'webp';
  return undefined;
}
