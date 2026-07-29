#!/usr/bin/env python3
"""Check the local proxy and AgentRouter model endpoint without making a chat call."""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request


def get_json(url: str, timeout: int) -> dict:
    request = urllib.request.Request(
        url,
        headers={"Accept": "application/json", "User-Agent": "proxy-setup-check/1"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        if response.status != 200:
            raise RuntimeError(f"{url} returned HTTP {response.status}")
        value = json.load(response)
        if not isinstance(value, dict):
            raise RuntimeError(f"{url} did not return a JSON object")
        return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--proxy-url", default="http://127.0.0.1:4182")
    parser.add_argument("--timeout", type=int, default=20)
    args = parser.parse_args()

    proxy_url = args.proxy_url.rstrip("/")
    try:
        health = get_json(f"{proxy_url}/health", args.timeout)
        if health.get("ok") is not True:
            raise RuntimeError("Proxy health response does not contain ok=true")
        print("[OK] Local proxy health")

        models = get_json(f"{proxy_url}/v1/models", args.timeout)
        model_data = models.get("data")
        if not isinstance(model_data, list):
            raise RuntimeError("AgentRouter /v1/models response has no data list")
        print(f"[OK] AgentRouter authentication and models ({len(model_data)} found)")
        return 0
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")[:500]
        print(f"[FAIL] HTTP {error.code}: {body}", file=sys.stderr)
    except Exception as error:
        print(f"[FAIL] {type(error).__name__}: {error}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
