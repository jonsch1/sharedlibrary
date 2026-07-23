/// <reference lib="webworker" />

import { build, files, version } from '$service-worker';

const worker = self as unknown as ServiceWorkerGlobalScope;
const cacheName = `shared-library-${version}`;
const applicationFiles = [...build, ...files];

worker.addEventListener('install', (event) => {
	event.waitUntil(caches.open(cacheName).then((cache) => cache.addAll(applicationFiles)));
});

worker.addEventListener('activate', (event) => {
	event.waitUntil(
		caches
			.keys()
			.then((keys) =>
				Promise.all(keys.filter((key) => key !== cacheName).map((key) => caches.delete(key)))
			)
			.then(() => worker.clients.claim())
	);
});

worker.addEventListener('fetch', (event) => {
	const url = new URL(event.request.url);
	if (event.request.method !== 'GET' || url.search) return;
	event.respondWith(
		caches.match(event.request).then((cached) => {
			if (cached) return cached;
			return fetch(event.request).then((response) => {
				if (
					response.ok &&
					url.origin === worker.location.origin
				) {
					const copy = response.clone();
					caches.open(cacheName).then((cache) => cache.put(event.request, copy));
				}
				return response;
			});
		})
	);
});
