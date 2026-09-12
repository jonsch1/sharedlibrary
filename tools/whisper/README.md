# Briefly transcription service

This tool deploys the Whisper `large-v3-turbo` transcription endpoint as the
Modal app `briefly-whisper`. It accepts a media URL or uploaded media and returns
transcript text. Requests carry a Briefly session token in the
`Authorization: Bearer …` header; the service reserves and releases transcription
usage through the hosted backend in [web](../../packages/web/).

Use an authenticated Modal CLI and a Python environment with `modal`, `fastapi`,
and `pydantic` installed. The service file defines the remote Python 3.12 CUDA
image, model dependencies, L4 GPU, and persistent model and media volumes. It is
deployed separately from the npm workspaces and Apple apps.

From the repository root, download the model into the cache before deploying:

```sh
modal run tools/whisper/modal_whisper_service.py::download
modal deploy tools/whisper/modal_whisper_service.py
```

The `BRIEFLY_API` constant in the service file selects the backend used for
session and usage authorization.
