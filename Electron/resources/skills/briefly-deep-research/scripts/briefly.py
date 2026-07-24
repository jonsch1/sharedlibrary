#!/usr/bin/env python3
"""Small standard-library client for the Briefly desktop agent API."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
import time
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import (
    ProxyHandler,
    Request,
    build_opener,
)


CONNECTION_RELATIVE_PATH = Path(".shared-library") / "agent-api.json"


def connection_path(explicit: str | None) -> Path:
    candidates: list[Path] = []
    if explicit:
        candidates.append(Path(explicit).expanduser())
    configured = os.environ.get("BRIEFLY_API_CONFIG") or os.environ.get(
        "SHARED_LIBRARY_API_CONFIG"
    )
    if configured:
        candidates.append(Path(configured).expanduser())
    for origin in (Path.cwd(), Path(__file__).resolve()):
        directory = origin if origin.is_dir() else origin.parent
        candidates.extend(
            parent / CONNECTION_RELATIVE_PATH
            for parent in (directory, *directory.parents)
        )

    seen: set[Path] = set()
    for candidate in candidates:
        resolved = candidate.resolve()
        if resolved in seen:
            continue
        seen.add(resolved)
        if resolved.is_file():
            return resolved
    raise RuntimeError(
        "Briefly API connection not found. Open or restart the desktop app "
        "with this workspace selected."
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
        with build_opener(ProxyHandler({})).open(request, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))
    except HTTPError as error:
        try:
            value = json.loads(error.read().decode("utf-8"))
            message = value.get("error", {}).get("message")
        except (json.JSONDecodeError, AttributeError):
            message = None
        raise RuntimeError(message or f"Briefly returned HTTP {error.code}.") from error
    except (URLError, TimeoutError) as error:
        raise RuntimeError(
            "Could not reach Briefly. Make sure the desktop app is running."
        ) from error


def print_json(value: dict[str, Any]) -> None:
    print(json.dumps(value, indent=2, ensure_ascii=False))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", help="Path to agent-api.json")
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("status")
    commands.add_parser("topics")

    create_topic = commands.add_parser("create-topic")
    create_topic.add_argument("--title", required=True)

    add_urls = commands.add_parser("add-urls")
    add_urls.add_argument("--topic", required=True)
    add_urls.add_argument(
        "--approved",
        action="store_true",
        help="Confirm the user approved this exact URL list.",
    )
    add_urls.add_argument("urls", nargs="+")

    job = commands.add_parser("job")
    job.add_argument("job_id")

    wait = commands.add_parser("wait")
    wait.add_argument("job_id")
    wait.add_argument("--interval", type=float, default=5)
    wait.add_argument("--timeout", type=float, default=3600)

    items = commands.add_parser("items")
    items.add_argument("--topic", required=True)
    items.add_argument(
        "--variant",
        choices=("brief", "concise", "detailed", "comprehensive", "source"),
        default="detailed",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    connection = load_connection(args.config)

    if args.command == "status":
        result = request_json(connection, "GET", "/v1/status")
    elif args.command == "topics":
        result = request_json(connection, "GET", "/v1/topics")
    elif args.command == "create-topic":
        result = request_json(
            connection, "POST", "/v1/topics", {"title": args.title}
        )
    elif args.command == "add-urls":
        if not args.approved:
            raise RuntimeError(
                "Refusing to add URLs without --approved. Obtain explicit user "
                "approval for the exact URL list first."
            )
        result = request_json(
            connection,
            "POST",
            f"/v1/topics/{quote(args.topic, safe='')}/sources",
            {"approved": True, "urls": args.urls},
        )
    elif args.command == "job":
        result = request_json(
            connection, "GET", f"/v1/jobs/{quote(args.job_id, safe='')}"
        )
    elif args.command == "wait":
        deadline = time.monotonic() + args.timeout
        while True:
            result = request_json(
                connection, "GET", f"/v1/jobs/{quote(args.job_id, safe='')}"
            )
            job = result.get("job", {})
            if job.get("status") == "completed":
                break
            if time.monotonic() >= deadline:
                raise RuntimeError("Timed out waiting for the import job.")
            counts = job.get("counts", {})
            print(
                "Waiting for Briefly: "
                f"{counts.get('completed', 0)} complete, "
                f"{counts.get('failed', 0)} failed...",
                file=sys.stderr,
            )
            time.sleep(max(1, args.interval))
    elif args.command == "items":
        result = request_json(
            connection,
            "GET",
            f"/v1/topics/{quote(args.topic, safe='')}/items"
            f"?variant={quote(args.variant, safe='')}",
        )
    else:
        raise RuntimeError(f"Unknown command: {args.command}")

    print_json(result)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
