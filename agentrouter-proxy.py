#!/usr/bin/env python3
"""Local AgentRouter compatibility proxy for 9Router.

The proxy keeps the AgentRouter API key outside 9Router, adapts OpenAI-style
requests for AgentRouter, relays SSE without buffering, and normalizes usage
metadata so 9Router can record token counts correctly.
"""

from __future__ import annotations

import argparse
import http.client
import json
import logging
import os
import socket
import socketserver
import ssl
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit


DEFAULT_UPSTREAM = "https://agentrouter.org"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 4182
MAX_UPSTREAM_ATTEMPTS = 3
UPSTREAM_HEADER_TIMEOUT_SECONDS = 20
UPSTREAM_STREAM_TIMEOUT_SECONDS = 180
RETRYABLE_UPSTREAM_STATUSES = {502, 503, 504}

# AgentRouter's compatibility endpoint expects these client-identification
# headers. They are static metadata and never contain the user's API key.
CLIENT_HEADERS = {
    "User-Agent": "RooCode/3.34.8",
    "X-Title": "Roo Code",
    "HTTP-Referer": "https://github.com/RooVetGit/Roo-Cline",
    "X-Stainless-Runtime-Version": "v22.20.0",
    "X-Stainless-Runtime": "node",
    "X-Stainless-Arch": "x64",
    "X-Stainless-OS": "Windows",
    "X-Stainless-Lang": "js",
}

HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}


def remove_null_fields(value: Any) -> Any:
    """Recursively remove null fields that can break upstream validation."""
    if isinstance(value, dict):
        return {
            key: remove_null_fields(item)
            for key, item in value.items()
            if item is not None
        }
    if isinstance(value, list):
        return [remove_null_fields(item) for item in value if item is not None]
    return value


def ensure_stream_usage(value: Any) -> Any:
    """Ask AgentRouter to include the final OpenAI usage chunk for SSE."""
    if not isinstance(value, dict) or value.get("stream") is not True:
        return value

    adapted = dict(value)
    stream_options = adapted.get("stream_options")
    stream_options = dict(stream_options) if isinstance(stream_options, dict) else {}
    stream_options["include_usage"] = True
    adapted["stream_options"] = stream_options
    return adapted


def adapt_9router_health_probe(value: Any) -> Any:
    """Turn 9Router's tiny Opus 5 probe into a reliable short completion."""
    if not isinstance(value, dict):
        return value

    messages = value.get("messages")
    is_9router_probe = (
        value.get("model") == "claude-opus-5"
        and value.get("stream") is False
        and value.get("max_tokens") == 16
        and messages == [{"role": "user", "content": "hi"}]
    )
    if not is_9router_probe:
        return value

    adapted = dict(value)
    adapted["max_tokens"] = 32
    adapted["messages"] = [{"role": "user", "content": "Reply exactly OK"}]
    logging.info("[ar] adapted 9Router health probe for claude-opus-5")
    return adapted


def normalize_response_usage(value: Any) -> Any:
    """Prefer real OpenAI token counts over zero-valued Claude aliases."""
    if not isinstance(value, dict) or not isinstance(value.get("usage"), dict):
        return value

    usage = dict(value["usage"])
    if usage.get("prompt_tokens") is not None and usage.get("input_tokens") == 0:
        usage.pop("input_tokens", None)
        if usage.get("input_tokens_details") is None:
            usage.pop("input_tokens_details", None)
    if usage.get("completion_tokens") is not None and usage.get("output_tokens") == 0:
        usage.pop("output_tokens", None)
        if usage.get("output_tokens_details") is None:
            usage.pop("output_tokens_details", None)

    normalized = dict(value)
    normalized["usage"] = usage
    return normalized


def normalize_sse_event(event: bytes) -> bytes | None:
    """Drop billing-only events and normalize usage inside SSE data lines."""
    if b"billing.summary" in event.lower():
        return None

    normalized_lines: list[bytes] = []
    for line in event.splitlines():
        if not line.startswith(b"data:"):
            normalized_lines.append(line)
            continue

        data = line[5:].strip()
        if not data or data == b"[DONE]":
            normalized_lines.append(line)
            continue

        try:
            payload = json.loads(data)
            payload = normalize_response_usage(payload)
            encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            normalized_lines.append(b"data: " + encoded)
        except (UnicodeDecodeError, json.JSONDecodeError):
            normalized_lines.append(line)

    return b"\n".join(normalized_lines)


def load_api_key(path: Path) -> str:
    """Load an AgentRouter key from the environment or a local ignored file."""
    environment_key = os.getenv("AGENTROUTER_API_KEY", "").strip().strip("\"'")
    if environment_key:
        return environment_key

    if not path.is_file():
        raise FileNotFoundError(
            f"AgentRouter API key not found. Create {path} or set "
            "AGENTROUTER_API_KEY."
        )

    key = path.read_text(encoding="utf-8").strip().strip("\"'")
    if not key or key == "paste-your-agentrouter-api-key-here":
        raise ValueError(f"AgentRouter API key is empty or still a placeholder: {path}")
    return key


class ProxyServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def server_bind(self) -> None:
        # Avoid reverse DNS during startup. This can otherwise delay binding on
        # Docker bridge addresses and some VPS networks.
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = str(host)
        self.server_port = int(port)

    def __init__(
        self,
        server_address: tuple[str, int],
        handler_class: type[BaseHTTPRequestHandler],
        *,
        upstream: str,
        api_key: str,
    ) -> None:
        super().__init__(server_address, handler_class)
        parsed = urlsplit(upstream)
        if parsed.scheme != "https" or not parsed.hostname:
            raise ValueError("Upstream must be an https URL")
        self.upstream_host = parsed.hostname
        self.upstream_port = parsed.port or 443
        self.upstream_prefix = parsed.path.rstrip("/")
        self.api_key = api_key
        self.ssl_context = ssl.create_default_context()

    def handle_error(self, request: object, client_address: object) -> None:
        # Windows health checks can reset a socket after receiving the response.
        import sys

        error = sys.exception()
        if isinstance(error, (ConnectionResetError, BrokenPipeError)):
            return
        super().handle_error(request, client_address)


class AgentRouterProxyHandler(BaseHTTPRequestHandler):
    server: ProxyServer
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: object) -> None:
        logging.info("%s - %s", self.address_string(), fmt % args)

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            payload = json.dumps({"ok": True}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self._proxy_request()

    def do_POST(self) -> None:  # noqa: N802
        self._proxy_request()

    def _request_body(self) -> bytes | None:
        content_length = int(self.headers.get("Content-Length", "0") or "0")
        if content_length <= 0:
            return None

        body = self.rfile.read(content_length)
        content_type = self.headers.get("Content-Type", "")
        if "application/json" not in content_type.lower():
            return body

        try:
            parsed = json.loads(body)
        except (UnicodeDecodeError, json.JSONDecodeError):
            return body

        cleaned = remove_null_fields(parsed)
        cleaned = ensure_stream_usage(cleaned)
        cleaned = adapt_9router_health_probe(cleaned)
        return json.dumps(cleaned, separators=(",", ":")).encode("utf-8")

    def _upstream_headers(self, body: bytes | None) -> dict[str, str]:
        headers = {
            "Authorization": f"Bearer {self.server.api_key}",
            "Content-Type": self.headers.get("Content-Type", "application/json"),
            "Accept": self.headers.get("Accept", "application/json"),
            **CLIENT_HEADERS,
        }
        if body is not None:
            headers["Content-Length"] = str(len(body))
        return headers

    def _proxy_request(self) -> None:
        body = self._request_body()
        upstream_path = f"{self.server.upstream_prefix}{self.path}"
        connection: http.client.HTTPSConnection | None = None
        response: http.client.HTTPResponse | None = None
        headers_sent = False

        try:
            for attempt in range(1, MAX_UPSTREAM_ATTEMPTS + 1):
                connection = http.client.HTTPSConnection(
                    self.server.upstream_host,
                    self.server.upstream_port,
                    timeout=UPSTREAM_HEADER_TIMEOUT_SECONDS,
                    context=self.server.ssl_context,
                )
                try:
                    connection.request(
                        self.command,
                        upstream_path,
                        body=body,
                        headers=self._upstream_headers(body),
                    )
                    response = connection.getresponse()
                except (TimeoutError, socket.timeout, ConnectionError) as exc:
                    connection.close()
                    connection = None
                    if attempt >= MAX_UPSTREAM_ATTEMPTS:
                        raise
                    logging.warning(
                        "[ar] upstream attempt %s/%s failed before headers: %s",
                        attempt,
                        MAX_UPSTREAM_ATTEMPTS,
                        exc,
                    )
                    time.sleep(0.25 * attempt)
                    continue

                if (
                    response.status in RETRYABLE_UPSTREAM_STATUSES
                    and attempt < MAX_UPSTREAM_ATTEMPTS
                ):
                    logging.warning(
                        "[ar] upstream attempt %s/%s returned HTTP %s; retrying",
                        attempt,
                        MAX_UPSTREAM_ATTEMPTS,
                        response.status,
                    )
                    connection.close()
                    connection = None
                    response = None
                    time.sleep(0.25 * attempt)
                    continue
                break

            if connection is None or response is None:
                raise RuntimeError("AgentRouter did not return a response")
            if connection.sock is not None:
                connection.sock.settimeout(UPSTREAM_STREAM_TIMEOUT_SECONDS)

            content_type = response.getheader("Content-Type", "")
            is_stream = "text/event-stream" in content_type.lower()

            self.send_response(response.status, response.reason)
            for name, value in response.getheaders():
                lowered = name.lower()
                if lowered in HOP_BY_HOP_HEADERS or lowered == "content-length":
                    continue
                self.send_header(name, value)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Connection", "close")
            self.end_headers()
            headers_sent = True
            self.close_connection = True

            if is_stream:
                self._relay_sse(response)
            else:
                payload = response.read()
                try:
                    decoded = json.loads(payload)
                    decoded = normalize_response_usage(decoded)
                    payload = json.dumps(decoded, separators=(",", ":")).encode("utf-8")
                except (UnicodeDecodeError, json.JSONDecodeError):
                    pass
                self.wfile.write(payload)
                self.wfile.flush()

            logging.info("[ar] %s %s -> %s", self.command, self.path, response.status)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            logging.info("[ar] client disconnected: %s %s", self.command, self.path)
        except Exception as exc:
            logging.exception("[ar] proxy error: %s", exc)
            if not headers_sent and not self.wfile.closed:
                try:
                    payload = json.dumps(
                        {"error": {"message": f"AgentRouter proxy error: {exc}"}}
                    ).encode("utf-8")
                    self.send_response(502)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                except Exception:
                    pass
        finally:
            if connection is not None:
                connection.close()

    def _relay_sse(self, response: http.client.HTTPResponse) -> None:
        event_lines: list[bytes] = []

        def relay_event() -> None:
            if not event_lines:
                return
            event = b"\n".join(event_lines)
            event_lines.clear()
            normalized = normalize_sse_event(event)
            if normalized is None:
                return
            self.wfile.write(normalized + b"\n\n")
            self.wfile.flush()

        # SSE is line-delimited. A large fixed-size read can hold small events
        # until a buffer fills, making a healthy stream appear frozen.
        while line := response.readline():
            normalized = line.rstrip(b"\r\n")
            if normalized:
                event_lines.append(normalized)
            else:
                relay_event()

        relay_event()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", default=DEFAULT_PORT, type=int)
    parser.add_argument("--upstream", default=DEFAULT_UPSTREAM)
    parser.add_argument(
        "--key-file",
        type=Path,
        default=Path(__file__).with_name("api.txt"),
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    api_key = load_api_key(args.key_file)
    server = ProxyServer(
        (args.host, args.port),
        AgentRouterProxyHandler,
        upstream=args.upstream,
        api_key=api_key,
    )
    logging.info(
        "AgentRouter proxy listening on http://%s:%s -> %s",
        args.host,
        args.port,
        args.upstream,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
