interface GoogleDrivePickerConfig {
	appID: string;
	oauthToken: string;
	developerKey?: string;
	folderID?: string;
}

export interface GoogleDriveFolderSelection {
	id: string;
	name: string;
}

interface PickerDocument {
	id?: unknown;
	name?: unknown;
	mimeType?: unknown;
}

interface PickerResponse {
	action?: unknown;
	docs?: unknown;
}

async function errorMessage(response: Response, fallback: string): Promise<string> {
	try {
		const value = (await response.json()) as { error?: string; message?: string };
		if (typeof value.error === 'string') return value.error;
		if (typeof value.message === 'string') return value.message;
	} catch {
		// The response was not JSON.
	}
	return fallback;
}

async function loadPickerConfig(): Promise<GoogleDrivePickerConfig> {
	const response = await fetch('/api/google/picker', {
		headers: { Accept: 'application/json' },
		cache: 'no-store'
	});
	if (!response.ok) {
		throw new Error(
			await errorMessage(response, 'The Google Drive folder picker could not be opened.')
		);
	}
	return (await response.json()) as GoogleDrivePickerConfig;
}

export async function chooseGoogleDriveFolder(): Promise<GoogleDriveFolderSelection | null> {
	const config = await loadPickerConfig();
	await import('@googleworkspace/drive-picker-element');

	return new Promise((resolve, reject) => {
		const picker = document.createElement('drive-picker');
		const view = document.createElement('drive-picker-docs-view');
		let settled = false;

		const finish = (result: GoogleDriveFolderSelection | null, error?: Error): void => {
			if (settled) return;
			settled = true;
			picker.remove();
			if (error) reject(error);
			else resolve(result);
		};

		picker.setAttribute('app-id', config.appID);
		picker.setAttribute('oauth-token', config.oauthToken);
		picker.setAttribute('origin', window.location.origin);
		picker.setAttribute(
			'title',
			config.folderID
				? 'Confirm the Shared Library group folder'
				: 'Choose the Shared Library group folder'
		);
		picker.setAttribute('max-items', '1');
		if (config.developerKey) picker.setAttribute('developer-key', config.developerKey);

		view.setAttribute('view-id', 'FOLDERS');
		view.setAttribute('enable-drives', 'true');
		view.setAttribute('include-folders', 'true');
		view.setAttribute('select-folder-enabled', 'true');
		view.setAttribute('mime-types', 'application/vnd.google-apps.folder');
		view.setAttribute('mode', 'LIST');
		if (config.folderID) view.setAttribute('file-ids', config.folderID);
		picker.append(view);

		picker.addEventListener('picker-picked', (event) => {
			const detail = (event as CustomEvent<PickerResponse>).detail;
			const documents = Array.isArray(detail?.docs) ? (detail.docs as PickerDocument[]) : [];
			const folder = documents[0];
			if (
				typeof folder?.id !== 'string' ||
				typeof folder.name !== 'string' ||
				folder.mimeType !== 'application/vnd.google-apps.folder'
			) {
				finish(
					null,
					new Error('Choose a Google Drive folder rather than an individual file.')
				);
				return;
			}
			if (config.folderID && folder.id !== config.folderID) {
				finish(null, new Error('Confirm the predefined Shared Library group folder.'));
				return;
			}
			finish({ id: folder.id, name: folder.name });
		});
		picker.addEventListener('picker-canceled', () => finish(null));
		picker.addEventListener('picker-error', () =>
			finish(
				null,
				new Error(
					'Google could not open the folder picker. Confirm that Google Picker API is enabled for the Shared Library Cloud project.'
				)
			)
		);
		document.body.append(picker);
	});
}
