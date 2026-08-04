"""Authenticated Whisper fallback for Briefly podcast and video transcripts.

Deploy:
    modal run Tools/whisper/modal_whisper_service.py::download
    modal deploy Tools/whisper/modal_whisper_service.py
"""

from math import ceil, isfinite
from ipaddress import ip_address
from pathlib import Path
import socket
from urllib.parse import urlparse
from uuid import uuid4

import modal
from fastapi import Header, Request
from pydantic import BaseModel, Field

MODEL = "large-v3-turbo"
CACHE = "/cache/huggingface"
MEDIA = Path("/media")
MAXIMUM_MEDIA_BYTES = 250_000_000
MAXIMUM_MEDIA_SECONDS = 4 * 60 * 60
BRIEFLY_API = "https://www.readbriefly.fyi"
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
    max_containers=3,
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

    lease = await _reserve_usage(authorization, "transcription", 0)
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
        duration = await _media_duration(paths[0])
        await _reserve_usage(
            authorization, "transcription", ceil(duration), lease
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
        await _release_usage(authorization, "transcription", lease)
        for path in MEDIA.glob(f"{job}.*"):
            path.unlink(missing_ok=True)
        media.commit()


async def _reserve_usage(
    authorization: str | None,
    service: str,
    units: int,
    lease_id: str | None = None,
) -> str:
    import httpx
    from fastapi import HTTPException

    token = (authorization or "").removeprefix("Bearer ").strip()
    if not token:
        raise HTTPException(status_code=401, detail="Sign in to Briefly.")
    async with httpx.AsyncClient(timeout=20) as client:
        response = await client.post(
            f"{BRIEFLY_API}/api/usage",
            headers={"Cookie": f"shared_library_session={token}"},
            json={
                "action": "reserve",
                "service": service,
                "units": units,
                **({"leaseID": lease_id} if lease_id else {}),
            },
        )
    if response.status_code != 200:
        try:
            detail = response.json().get("error")
        except Exception:
            detail = None
        raise HTTPException(
            status_code=response.status_code,
            detail=detail or "Briefly could not authorize this transcription.",
        )
    return response.json()["leaseID"]


async def _release_usage(
    authorization: str | None, service: str, lease_id: str | None
) -> None:
    import httpx

    token = (authorization or "").removeprefix("Bearer ").strip()
    if not token or not lease_id:
        return
    try:
        async with httpx.AsyncClient(timeout=20) as client:
            await client.post(
                f"{BRIEFLY_API}/api/usage",
                headers={"Cookie": f"shared_library_session={token}"},
                json={
                    "action": "release",
                    "service": service,
                    "leaseID": lease_id,
                },
            )
    except Exception as error:
        print(f"Usage lease release failed: {error}", flush=True)


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
        if any(path.stat().st_size > MAXIMUM_MEDIA_BYTES for path in paths):
            raise ValueError("Media is too large to transcribe.")
        return paths
    return [await _download_podcast_media(url, job)]


async def _download_podcast_media(url: str, job: str) -> Path:
    import httpx

    path = MEDIA / f"{job}.media"
    current = url
    async with httpx.AsyncClient(timeout=httpx.Timeout(180, connect=20)) as client:
        for _ in range(6):
            _validated_public_media_url(current)
            async with client.stream(
                "GET",
                current,
                headers={"Accept": "audio/*,application/octet-stream;q=0.5,*/*;q=0.1"},
                follow_redirects=False,
            ) as response:
                if response.is_redirect:
                    location = response.headers.get("location")
                    if not location:
                        raise ValueError("Podcast media returned an invalid redirect.")
                    current = str(response.url.join(location))
                    continue
                response.raise_for_status()
                length = response.headers.get("content-length")
                if length and int(length) > MAXIMUM_MEDIA_BYTES:
                    raise ValueError("Media is too large to transcribe.")
                written = 0
                with path.open("wb") as output:
                    async for chunk in response.aiter_bytes():
                        written += len(chunk)
                        if written > MAXIMUM_MEDIA_BYTES:
                            raise ValueError("Media is too large to transcribe.")
                        output.write(chunk)
                if written == 0:
                    raise ValueError("Podcast media was empty.")
                return path
    raise ValueError("Podcast media redirected too many times.")


async def _media_duration(path: Path) -> float:
    import asyncio

    process = await asyncio.create_subprocess_exec(
        "ffprobe",
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
        str(path),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    output, errors = await process.communicate()
    try:
        duration = float(output.decode().strip())
    except ValueError as error:
        raise ValueError("Media duration could not be read.") from error
    if process.returncode != 0 or not isfinite(duration) or duration <= 0:
        message = errors.decode(errors="replace").strip()
        raise ValueError(message or "Media duration could not be read.")
    if duration > MAXIMUM_MEDIA_SECONDS:
        raise ValueError("Media must be four hours or shorter.")
    return duration


def _validated_url(raw_url: str) -> str:
    parsed = urlparse(raw_url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ValueError("Only HTTP(S) media URLs are supported.")
    if parsed.username or parsed.password:
        raise ValueError("Media URLs cannot contain credentials.")
    if parsed.hostname.lower() not in YOUTUBE_HOSTS:
        _validated_public_media_url(raw_url)
    return raw_url


def _validated_public_media_url(raw_url: str) -> None:
    parsed = urlparse(raw_url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ValueError("Only HTTP(S) media URLs are supported.")
    if parsed.username or parsed.password:
        raise ValueError("Media URLs cannot contain credentials.")
    if parsed.port not in {None, 80, 443}:
        raise ValueError("Podcast media must use the standard HTTP(S) port.")
    try:
        addresses = {
            result[4][0]
            for result in socket.getaddrinfo(
                parsed.hostname,
                parsed.port or (443 if parsed.scheme == "https" else 80),
            )
        }
    except socket.gaierror as error:
        raise ValueError("Podcast media host could not be resolved.") from error
    if not addresses or any(not ip_address(value).is_global for value in addresses):
        raise ValueError("Podcast media must use a public internet host.")


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
