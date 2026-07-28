"""Kokoro-82M speech endpoint for Briefly podcasts.

Deploy:
    modal run Tools/kokoro/modal_kokoro_service.py::download
    modal deploy Tools/kokoro/modal_kokoro_service.py
"""

from io import BytesIO

import modal
from fastapi import Header
from pydantic import BaseModel, Field

MODEL = "hexgrad/Kokoro-82M"
VOICE = "af_heart"
SAMPLE_RATE = 24_000

app = modal.App("briefly-kokoro")
cache = modal.Volume.from_name("kokoro-cache", create_if_missing=True)
image = (
    modal.Image.debian_slim(python_version="3.12")
    .apt_install("espeak-ng", "libsndfile1")
    .uv_pip_install("kokoro==0.9.4", "soundfile", "httpx", "fastapi")
    .run_commands("python -m spacy download en_core_web_sm")
    .env({"HF_HOME": "/cache/huggingface"})
)


class SpeechRequest(BaseModel):
    text: str = Field(min_length=1, max_length=120_000)


@app.function(image=image, volumes={"/cache": cache}, cpu=1, timeout=1800)
def download() -> str:
    from huggingface_hub import hf_hub_download

    for filename in ("config.json", "kokoro-v1_0.pth", f"voices/{VOICE}.pt"):
        hf_hub_download(MODEL, filename)
    cache.commit()
    return MODEL


@app.cls(
    image=image,
    gpu="L4",
    volumes={"/cache": cache},
    min_containers=0,
    max_containers=1,
    scaledown_window=2,
    timeout=1800,
)
class Kokoro:
    @modal.enter()
    def load(self):
        import torch
        from huggingface_hub import hf_hub_download
        from kokoro import KModel

        torch.set_float32_matmul_precision("high")
        self.torch = torch
        self.model = KModel(repo_id=MODEL).to("cuda").eval()
        self.voice = torch.load(
            hf_hub_download(MODEL, f"voices/{VOICE}.pt"),
            weights_only=True,
        )

    @modal.batched(max_batch_size=2, wait_ms=1_000)
    def generate(self, batches: list[list[str]]) -> list[bytes]:
        import numpy
        import soundfile

        encoded = []
        with self.torch.inference_mode():
            for phonemes in batches:
                waveforms = []
                for value in phonemes:
                    if not 1 <= len(value) <= len(self.voice):
                        raise ValueError("Kokoro produced an invalid phoneme segment.")
                    reference = self.voice[len(value) - 1].to("cuda")
                    ids = self.torch.LongTensor(
                        [[0, *(self.model.vocab[c] for c in value if c in self.model.vocab), 0]]
                    ).to("cuda")
                    waveforms.append(
                        self.model.forward_with_tokens(ids, reference)[0]
                        .float()
                        .cpu()
                        .numpy()
                    )
                buffer = BytesIO()
                soundfile.write(
                    buffer,
                    numpy.concatenate(waveforms),
                    SAMPLE_RATE,
                    format="WAV",
                    subtype="PCM_16",
                )
                encoded.append(buffer.getvalue())
        return encoded


@app.function(image=image, cpu=1, scaledown_window=2, timeout=1800)
@modal.fastapi_endpoint(method="POST")
async def speech(
    request: SpeechRequest,
    authorization: str | None = Header(default=None),
):
    import httpx
    from fastapi import HTTPException, Response
    from kokoro import KPipeline

    if authorization is None:
        raise HTTPException(status_code=401, detail="Sign in to Briefly.")
    token = authorization.removeprefix("Bearer ").strip()
    if not token:
        raise HTTPException(status_code=401, detail="Sign in to Briefly.")
    async with httpx.AsyncClient(timeout=20) as client:
        account = await client.get(
            "https://www.readbriefly.fyi/api/billing/status",
            headers={"Cookie": f"shared_library_session={token}"},
        )
    if account.status_code != 200 or not account.json().get("entitled"):
        raise HTTPException(status_code=403, detail="A Briefly subscription is required.")

    pipeline = KPipeline(lang_code="a", repo_id=MODEL, model=False)
    phonemes = [
        result.phonemes
        for result in pipeline(request.text.strip(), model=False)
        if result.phonemes
    ]
    if not phonemes:
        raise HTTPException(status_code=400, detail="The podcast contains no speakable text.")
    audio = await Kokoro().generate.remote.aio(phonemes)
    return Response(audio, media_type="audio/wav")
