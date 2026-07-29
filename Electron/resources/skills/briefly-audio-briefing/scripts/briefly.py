#!/usr/bin/env python3
"""Use Briefly's local agent API for private audio briefings."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import ProxyHandler, Request, build_opener


CONNECTION_RELATIVE_PATH = Path(".shared-library") / "agent-api.json"


def connection_path(explicit: str | None) -> Path:
    candidates: list[Path] = []
    if explicit:
        candidates.append(Path(explicit).expanduser())
    configured = os.environ.get("BRIEFLY_API_CONFIG")
    if configured:
        candidates.append(Path(configured).expanduser())
    for origin in (Path.cwd(), Path(__file__).resolve()):
        directory = origin if origin.is_dir() else origin.parent
        candidates.extend(
            parent / CONNECTION_RELATIVE_PATH
            for parent in (directory, *directory.parents)
        )
    for candidate in dict.fromkeys(path.resolve() for path in candidates):
        if candidate.is_file():
            return candidate
    raise RuntimeError(
        "Briefly API connection not found. Open or restart Briefly with this "
        "workspace selected."
    )


def load_connection(explicit: str | None) -> dict[str, Any]:
    path = connection_path(explicit)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"Could not read {path}: {error}") from error
    if not isinstance(value.get("baseURL"), str) or not isinstance(
        value.get("token"), str
    ):
        raise RuntimeError(f"The connection file is invalid: {path}")
    return value


def request_json(
    connection: dict[str, Any],
    method: str,
    path: str,
    body: dict[str, Any] | None = None,
) -> dict[str, Any]:
    payload = None if body is None else json.dumps(body).encode("utf-8")
    request = Request(
        f"{connection['baseURL']}{path}",
        data=payload,
        method=method,
        headers={
            "Authorization": f"Bearer {connection['token']}",
            "Accept": "application/json",
            "Content-Type": "application/json",
        },
    )
    try:
        with build_opener(ProxyHandler({})).open(request, timeout=1900) as response:
            return json.loads(response.read().decode("utf-8"))
    except HTTPError as error:
        try:
            message = json.loads(error.read().decode("utf-8")).get("error", {}).get(
                "message"
            )
        except (json.JSONDecodeError, AttributeError):
            message = None
        raise RuntimeError(message or f"Briefly returned HTTP {error.code}.") from error
    except (URLError, TimeoutError) as error:
        raise RuntimeError(
            "Could not reach Briefly. Make sure the desktop app is running."
        ) from error


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", help="Path to agent-api.json")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status")
    commands.add_parser("podcasts")
    extract = commands.add_parser("extract")
    extract.add_argument("url")
    create = commands.add_parser("create-episode")
    create.add_argument("--podcast", required=True)
    create.add_argument("--request", required=True, type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    connection = load_connection(args.config)
    if args.command == "status":
        result = request_json(connection, "GET", "/v1/status")
    elif args.command == "podcasts":
        result = request_json(connection, "GET", "/v1/podcasts")
    elif args.command == "extract":
        result = request_json(connection, "POST", "/v1/extract", {"url": args.url})
    elif args.command == "create-episode":
        try:
            payload = json.loads(args.request.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise RuntimeError(f"Could not read episode request: {error}") from error
        if not isinstance(payload, dict):
            raise RuntimeError("The episode request must be a JSON object.")
        result = request_json(
            connection,
            "POST",
            f"/v1/podcasts/{quote(args.podcast, safe='')}/episodes",
            payload,
        )
    else:
        raise RuntimeError(f"Unknown command: {args.command}")
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
