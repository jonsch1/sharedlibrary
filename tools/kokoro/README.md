# Briefly speech service

This tool deploys the Kokoro-82M voice endpoint as the Modal app
`briefly-kokoro`. It accepts text and returns WAV audio. Requests carry a Briefly
session token in the `Authorization: Bearer …` header; the service reserves and
releases voice usage through the hosted backend in [web](../../packages/web/).

Use an authenticated Modal CLI and a Python environment with `modal`, `fastapi`,
and `pydantic` installed. The service file defines the remote Python 3.12 image,
model dependencies, L4 GPU, and persistent model cache. It is deployed separately
from the npm workspaces and Apple apps.

From the repository root, download the model into the cache before deploying:

```sh
modal run tools/kokoro/modal_kokoro_service.py::download
modal deploy tools/kokoro/modal_kokoro_service.py
```

The `BRIEFLY_API` constant in the service file selects the backend used for
session and usage authorization.
