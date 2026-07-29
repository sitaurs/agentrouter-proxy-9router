from __future__ import annotations

import importlib.util
import io
import json
import os
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "agentrouter_proxy", ROOT / "agentrouter-proxy.py"
)
assert SPEC is not None and SPEC.loader is not None
PROXY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROXY)


class ProxyTransformTests(unittest.TestCase):
    def test_remove_null_fields_recursively(self) -> None:
        value = {
            "keep": 1,
            "drop": None,
            "nested": {"drop": None, "keep": "ok"},
            "items": [None, {"drop": None, "keep": True}],
        }
        self.assertEqual(
            PROXY.remove_null_fields(value),
            {
                "keep": 1,
                "nested": {"keep": "ok"},
                "items": [{"keep": True}],
            },
        )

    def test_stream_usage_is_enabled(self) -> None:
        value = {"stream": True, "stream_options": {"other": "value"}}
        adapted = PROXY.ensure_stream_usage(value)
        self.assertTrue(adapted["stream_options"]["include_usage"])
        self.assertEqual(adapted["stream_options"]["other"], "value")

    def test_non_stream_request_is_not_changed(self) -> None:
        value = {"stream": False}
        self.assertIs(PROXY.ensure_stream_usage(value), value)

    def test_health_probe_is_adapted(self) -> None:
        value = {
            "model": "claude-opus-5",
            "stream": False,
            "max_tokens": 16,
            "messages": [{"role": "user", "content": "hi"}],
        }
        adapted = PROXY.adapt_9router_health_probe(value)
        self.assertEqual(adapted["max_tokens"], 32)
        self.assertEqual(
            adapted["messages"],
            [{"role": "user", "content": "Reply exactly OK"}],
        )

    def test_usage_prefers_real_openai_counts(self) -> None:
        value = {
            "usage": {
                "prompt_tokens": 120,
                "completion_tokens": 8,
                "input_tokens": 0,
                "output_tokens": 0,
            }
        }
        normalized = PROXY.normalize_response_usage(value)
        self.assertEqual(
            normalized["usage"],
            {"prompt_tokens": 120, "completion_tokens": 8},
        )

    def test_sse_usage_is_normalized(self) -> None:
        payload = {
            "choices": [],
            "usage": {
                "prompt_tokens": 12,
                "completion_tokens": 3,
                "input_tokens": 0,
                "output_tokens": 0,
            },
        }
        event = b"data: " + json.dumps(payload).encode("utf-8")
        normalized = PROXY.normalize_sse_event(event)
        self.assertIsNotNone(normalized)
        data = json.loads(normalized.split(b":", 1)[1].strip())
        self.assertEqual(
            data["usage"],
            {"prompt_tokens": 12, "completion_tokens": 3},
        )

    def test_billing_event_is_dropped(self) -> None:
        self.assertIsNone(
            PROXY.normalize_sse_event(b'event: billing.summary\ndata: {"cost":1}')
        )

    def test_first_stream_error_is_detected(self) -> None:
        event = b'data: {"error":{"message":"upstream failed","type":"api_error"}}'
        status, payload = PROXY.extract_sse_error(event)
        self.assertEqual(status, 502)
        self.assertEqual(payload["error"]["message"], "upstream failed")

    def test_sensitive_word_stream_error_is_not_retried(self) -> None:
        event = (
            b'data: {"error":{"message":"sensitive words detected",'
            b'"code":"sensitive_words_detected"}}'
        )
        status, payload = PROXY.extract_sse_error(event)
        self.assertEqual(status, 400)
        self.assertEqual(payload["error"]["code"], "sensitive_words_detected")

    def test_sse_reader_returns_complete_events(self) -> None:
        response = io.BytesIO(b"data: one\r\nid: 1\r\n\r\ndata: two\n\n")
        self.assertEqual(
            PROXY.read_sse_event(response),
            b"data: one\nid: 1",
        )
        self.assertEqual(PROXY.read_sse_event(response), b"data: two")
        self.assertIsNone(PROXY.read_sse_event(response))

    def test_sse_done_event_is_detected(self) -> None:
        self.assertTrue(PROXY.is_sse_done(b"event: message\ndata: [DONE]"))
        self.assertFalse(PROXY.is_sse_done(b'data: {"choices":[]}'))


class ApiKeyTests(unittest.TestCase):
    def test_environment_key_has_priority(self) -> None:
        with mock.patch.dict(
            os.environ, {"AGENTROUTER_API_KEY": "env-secret"}, clear=True
        ):
            self.assertEqual(
                PROXY.load_default_api_key(Path("missing.txt")), "env-secret"
            )

    def test_key_can_be_loaded_from_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            key_file = Path(directory) / "api.txt"
            key_file.write_text("file-secret\n", encoding="utf-8")
            with mock.patch.dict(os.environ, {}, clear=True):
                self.assertEqual(PROXY.load_default_api_key(key_file), "file-secret")

    def test_example_placeholder_becomes_no_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            key_file = Path(directory) / "api.txt"
            key_file.write_text(
                "paste-your-agentrouter-api-key-here", encoding="utf-8"
            )
            with mock.patch.dict(os.environ, {}, clear=True):
                self.assertIsNone(PROXY.load_default_api_key(key_file))

    def test_missing_file_becomes_no_fallback(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertIsNone(PROXY.load_default_api_key(Path("missing.txt")))

    def test_inbound_9router_key_has_priority(self) -> None:
        self.assertEqual(
            PROXY.select_upstream_api_key("Bearer dashboard-key", "file-key"),
            "dashboard-key",
        )

    def test_placeholder_uses_fallback_key(self) -> None:
        self.assertEqual(
            PROXY.select_upstream_api_key("Bearer local-proxy", "file-key"),
            "file-key",
        )

    def test_documentation_placeholder_uses_fallback_key(self) -> None:
        self.assertEqual(
            PROXY.select_upstream_api_key(
                "Bearer YOUR_AGENTROUTER_API_KEY", "file-key"
            ),
            "file-key",
        )

    def test_missing_key_is_rejected(self) -> None:
        with self.assertRaises(PermissionError):
            PROXY.select_upstream_api_key("Bearer local-proxy", None)


class ProxyHttpTests(unittest.TestCase):
    def run_server(self, api_key: str | None = None):
        server = PROXY.ProxyServer(
            ("127.0.0.1", 0),
            PROXY.AgentRouterProxyHandler,
            upstream="https://agentrouter.invalid",
            api_key=api_key,
        )
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(thread.join, 2)
        self.addCleanup(server.shutdown)
        return server

    def test_missing_key_returns_http_401_before_upstream(self) -> None:
        server = self.run_server()
        url = f"http://127.0.0.1:{server.server_port}/v1/models"
        with self.assertRaises(urllib.error.HTTPError) as raised:
            urllib.request.urlopen(url, timeout=2)
        self.assertEqual(raised.exception.code, 401)
        payload = json.load(raised.exception)
        self.assertEqual(
            payload["error"]["code"],
            "missing_agentrouter_api_key",
        )

    def test_http_200_sse_error_becomes_real_http_error(self) -> None:
        captured_headers: list[dict[str, str]] = []
        opener = urllib.request.build_opener()

        class FakeSocket:
            def settimeout(self, timeout: int) -> None:
                self.timeout = timeout

        class FakeResponse:
            status = 200
            reason = "OK"

            def __init__(self) -> None:
                self.stream = io.BytesIO(
                    b'data: {"error":{"message":"sensitive words detected",'
                    b'"code":"sensitive_words_detected"}}\n\n'
                )

            def getheader(self, name: str, default: str = "") -> str:
                if name.lower() == "content-type":
                    return "text/event-stream"
                return default

            def getheaders(self) -> list[tuple[str, str]]:
                return [("Content-Type", "text/event-stream")]

            def readline(self) -> bytes:
                return self.stream.readline()

        class FakeConnection:
            debuglevel = 0

            def __init__(self, *args, **kwargs) -> None:
                self.sock = FakeSocket()

            def request(self, method, path, body=None, headers=None) -> None:
                captured_headers.append(dict(headers or {}))

            def getresponse(self):
                return FakeResponse()

            def close(self) -> None:
                pass

        with mock.patch.object(
            PROXY.http.client, "HTTPSConnection", FakeConnection
        ):
            server = self.run_server()
            url = (
                f"http://127.0.0.1:{server.server_port}/v1/chat/completions"
            )
            request = urllib.request.Request(
                url,
                method="POST",
                headers={
                    "Authorization": "Bearer dashboard-agentrouter-key",
                    "Content-Type": "application/json",
                },
                data=b'{"model":"gpt-5.6-sol","stream":true,"messages":[]}',
            )
            with self.assertRaises(urllib.error.HTTPError) as raised:
                opener.open(request, timeout=2)
            self.assertEqual(raised.exception.code, 400)
            payload = json.load(raised.exception)
            self.assertEqual(
                payload["error"]["code"],
                "sensitive_words_detected",
            )

        self.assertEqual(len(captured_headers), 1)
        self.assertEqual(
            captured_headers[0]["Authorization"],
            "Bearer dashboard-agentrouter-key",
        )


if __name__ == "__main__":
    unittest.main()
