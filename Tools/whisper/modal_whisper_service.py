"""Authenticated Whisper fallback for Briefly podcast and video transcripts.

Deploy:
    modal run Tools/whisper/modal_whisper_service.py::download
    modal deploy Tools/whisper/modal_whisper_service.py
"""

from ipaddress import ip_address
from pathlib import Path
from socket import getaddrinfo
from urllib.parse import urlparse
from uuid import uuid4

import modal
from fastapi import Header, Request
from pydantic import BaseModel, Field

MODEL = "large-v3-turbo"
CACHE = "/cache/huggingface"
MEDIA = Path("/media")
MAXIMUM_MEDIA_BYTES = 2_000_000_000
YOUTUBE_HOSTS = {
    "youtu.be",
    "youtube.com",
    "www.youtube.com",
    "m.youtube.com",
    "music.youtube.com",
}

app = modal.App("briefly-whisper")
cache = modal.Volume.from_name("briefly-whisper-cache", create_if_missing=True)
media = modal.Volume.from_name("briefly-whisper-media", create_if_missing=True)
image = (
    modal.Image.from_registry(
        "nvidia/cuda:12.9.0-cudnn-runtime-ubuntu24.04", add_python="3.12"
    )
    .apt_install("ffmpeg")
    .uv_pip_install(
        "ctranslate2==4.8.1",
        "faster-whisper==1.2.1",
        "fastapi",
        "httpx",
        "yt-dlp",
    )
    .env({"HF_HOME": CACHE})
)


class TranscriptionRequest(BaseModel):
    url: str = Field(min_length=8, max_length=8_192)
    include_timestamps: bool = False


@app.function(image=image, volumes={"/cache": cache}, timeout=1800)
def download() -> str:
    from faster_whisper.utils import download_model

    path = download_model(MODEL, cache_dir=CACHE)
    cache.commit()
    return path


@app.cls(
    image=image,
    gpu="L4",
    cpu=1,
    memory=4096,
    volumes={"/cache": cache, "/media": media},
    min_containers=0,
    scaledown_window=2,
    timeout=1800,
)
class Whisper:
    @modal.enter()
    def load(self):
        from faster_whisper import BatchedInferencePipeline, WhisperModel

        model = WhisperModel(
            MODEL,
            device="cuda",
            compute_type="int8_float16",
            download_root=CACHE,
            local_files_only=True,
            cpu_threads=1,
            num_workers=1,
        )
        self.transcriber = BatchedInferencePipeline(model=model)

    @modal.method()
    def transcribe(self, path: str) -> dict:
        media.reload()
        segments, info = self.transcriber.transcribe(
            path,
            batch_size=64,
            beam_size=1,
            language="en",
            vad_filter=True,
            condition_on_previous_text=False,
            word_timestamps=False,
        )
        rows = [
            {
                "start_milliseconds": round(segment.start * 1000),
                "text": segment.text.strip(),
            }
            for segment in segments
            if segment.text.strip()
        ]
        if not rows:
            raise ValueError("Whisper did not find any speech in this media.")
        return {"language": info.language, "segments": rows}


@app.function(
    image=image,
    cpu=1,
    volumes={"/media": media},
    scaledown_window=2,
    timeout=1800,
)
@modal.fastapi_endpoint(method="POST")
async def transcribe(
    request: Request,
    authorization: str | None = Header(default=None),
):
    from fastapi import HTTPException

    await _require_subscription(authorization)
    job = uuid4().hex
    paths: list[Path] = []
    try:
        if request.headers.get("content-type", "").startswith("application/json"):
            payload = TranscriptionRequest.model_validate(await request.json())
            paths = await _download_media(payload.url, job)
            include_timestamps = payload.include_timestamps
        else:
            path = MEDIA / f"{job}.media"
            written = 0
            with path.open("wb") as output:
                async for chunk in request.stream():
                    written += len(chunk)
                    if written > MAXIMUM_MEDIA_BYTES:
                        raise ValueError("Media is too large to transcribe.")
                    output.write(chunk)
            if written == 0:
                raise ValueError("Uploaded media was empty.")
            paths = [path]
            include_timestamps = (
                request.headers.get("x-briefly-include-timestamps") == "1"
            )
        media.commit()
        result = await Whisper().transcribe.remote.aio(str(paths[0]))
        return {
            "text": _format_transcript(
                result["segments"], include_timestamps
            ),
            "language": result["language"],
        }
    except HTTPException:
        raise
    except Exception as error:
        print(f"Transcription failed: {error}", flush=True)
        raise HTTPException(status_code=422, detail=str(error)) from error
    finally:
        for path in MEDIA.glob(f"{job}.*"):
            path.unlink(missing_ok=True)
        media.commit()


async def _require_subscription(authorization: str | None) -> None:
    import httpx
    from fastapi import HTTPException

    token = (authorization or "").removeprefix("Bearer ").strip()
    if not token:
        raise HTTPException(status_code=401, detail="Sign in to Briefly.")
    async with httpx.AsyncClient(timeout=20) as client:
        account = await client.get(
            "https://www.readbriefly.fyi/api/billing/status",
            headers={"Cookie": f"shared_library_session={token}"},
        )
    if account.status_code != 200 or not account.json().get("entitled"):
        raise HTTPException(
            status_code=403, detail="A Briefly subscription is required."
        )


async def _download_media(raw_url: str, job: str) -> list[Path]:
    import asyncio
    import glob

    url = _validated_url(raw_url)
    if urlparse(url).hostname.lower() in YOUTUBE_HOSTS:
        template = str(MEDIA / f"{job}.%(ext)s")
        process = await asyncio.create_subprocess_exec(
            "yt-dlp",
            "--no-playlist",
            "--extract-audio",
            "--audio-format",
            "wav",
            "--output",
            template,
            url,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
        _, errors = await process.communicate()
        paths = [Path(value) for value in glob.glob(str(MEDIA / f"{job}.*"))]
        if process.returncode != 0 or not paths:
            message = errors.decode(errors="replace").strip().splitlines()
            raise ValueError(message[-1] if message else "YouTube audio download failed.")
        return paths

    destination = MEDIA / f"{job}.media"
    await _download_direct(url, destination)
    return [destination]


async def _download_direct(raw_url: str, destination: Path) -> None:
    import httpx

    url = raw_url
    async with httpx.AsyncClient(timeout=120, follow_redirects=False) as client:
        for _ in range(12):
            _validated_url(url)
            async with client.stream("GET", url) as response:
                if response.is_redirect:
                    location = response.headers.get("location")
                    if not location:
                        raise ValueError("Media redirect had no destination.")
                    url = str(response.url.join(location))
                    continue
                response.raise_for_status()
                declared = int(response.headers.get("content-length", "0") or 0)
                if declared > MAXIMUM_MEDIA_BYTES:
                    raise ValueError("Media is too large to transcribe.")
                written = 0
                with destination.open("wb") as output:
                    async for chunk in response.aiter_bytes():
                        written += len(chunk)
                        if written > MAXIMUM_MEDIA_BYTES:
                            raise ValueError("Media is too large to transcribe.")
                        output.write(chunk)
                if written == 0:
                    raise ValueError("Media download was empty.")
                return
        raise ValueError("Media redirected too many times.")


def _validated_url(raw_url: str) -> str:
    parsed = urlparse(raw_url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ValueError("Only HTTP(S) media URLs are supported.")
    if parsed.username or parsed.password:
        raise ValueError("Media URLs cannot contain credentials.")
    for result in getaddrinfo(
        parsed.hostname, parsed.port or (443 if parsed.scheme == "https" else 80)
    ):
        address = ip_address(result[4][0])
        if not address.is_global:
            raise ValueError("Private network media URLs are not supported.")
    return raw_url


def _format_transcript(segments: list[dict], include_timestamps: bool) -> str:
    return "\n".join(
        (
            f"[{_timestamp(segment['start_milliseconds'])}] {segment['text']}"
            if include_timestamps
            else segment["text"]
        )
        for segment in segments
    )


def _timestamp(milliseconds: int) -> str:
    seconds = max(0, milliseconds // 1000)
    hours, remainder = divmod(seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    return (
        f"{hours}:{minutes:02d}:{seconds:02d}"
        if hours
        else f"{minutes}:{seconds:02d}"
    )
