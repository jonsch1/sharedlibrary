import tailwindcss from '@tailwindcss/vite';
import adapter from '@sveltejs/adapter-static';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

export default defineConfig({
	build: {
		// The CSP allows fonts only from 'self', so never inline small font subsets as data: URLs.
		assetsInlineLimit: (file) => (file.endsWith('.woff2') || file.endsWith('.woff') ? false : undefined)
	},
	plugins: [
		tailwindcss(),
		sveltekit({
			csp: {
				mode: 'hash',
				directives: {
					'default-src': ['self'],
					'script-src': ['self'],
					'style-src': ['self', 'unsafe-inline'],
					'font-src': ['self'],
					'img-src': ['self', 'data:', 'blob:'],
					'media-src': ['self', 'blob:'],
					'connect-src': ['self', 'https://*.apple.com', 'https://*.posthog.com'],
					'frame-src': ['https://*.apple.com'],
					'object-src': ['none'],
					'base-uri': ['self'],
					'form-action': ['self'],
					'frame-ancestors': ['none']
				}
			},
			compilerOptions: {
				// Force runes mode for the project, except for libraries. Can be removed in svelte 6.
				runes: ({ filename }) => filename.split(/[/\\]/).includes('node_modules') ? undefined : true
			},
			adapter: adapter()
		})
	]
});
