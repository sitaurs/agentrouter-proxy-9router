from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import unittest
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


class ApiKeyTests(unittest.TestCase):
    def test_environment_key_has_priority(self) -> None:
        with mock.patch.dict(
            os.environ, {"AGENTROUTER_API_KEY": "env-secret"}, clear=True
        ):
            self.assertEqual(PROXY.load_api_key(Path("missing.txt")), "env-secret")

    def test_key_can_be_loaded_from_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            key_file = Path(directory) / "api.txt"
            key_file.write_text("file-secret\n", encoding="utf-8")
            with mock.patch.dict(os.environ, {}, clear=True):
                self.assertEqual(PROXY.load_api_key(key_file), "file-secret")

    def test_example_placeholder_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            key_file = Path(directory) / "api.txt"
            key_file.write_text(
                "paste-your-agentrouter-api-key-here", encoding="utf-8"
            )
            with mock.patch.dict(os.environ, {}, clear=True):
                with self.assertRaises(ValueError):
                    PROXY.load_api_key(key_file)


if __name__ == "__main__":
    unittest.main()
