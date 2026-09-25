"""Exercise the built service through HTTP and the official OpenAI client."""
import concurrent.futures
import json
import os
from pathlib import Path
import sys
import time
import unittest

import httpx
from openai import OpenAI


BASE = os.environ.get("ELIZA_URL", "http://eliza:8080")
OPEN_BASE = os.environ.get("ELIZA_OPEN_URL", "http://eliza-open:8080")
KEY = "docker-test-key"
HEADERS = {"Authorization": f"Bearer {KEY}"}
MODE = sys.argv[1]
TURNS = [
    "hello", "I remember my mother and my father", "I feel sad and I want help",
    "my bicycle is blue", "zzzxxy", "you remind me of my mother",
    "I am unhappy because I dream", "hello", "hello", "my café is beautiful", "zzzxxy",
]


def ready(base):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        try:
            if httpx.get(base + "/healthz", timeout=2).status_code == 200:
                return
        except httpx.HTTPError:
            pass
        time.sleep(0.2)
    raise RuntimeError(f"Service did not become ready: {base}")


class EndToEnd(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        ready(BASE)
        ready(OPEN_BASE)
        cls.client = OpenAI(base_url=BASE + "/v1", api_key=KEY,
                            timeout=10, max_retries=0, _strict_response_validation=True)

    @classmethod
    def tearDownClass(cls):
        cls.client.close()

    def completion(self, messages, **kwargs):
        return self.client.chat.completions.create(model="eliza", messages=messages, **kwargs)

    def test_models_health_and_authentication(self):
        self.assertEqual([m.id for m in self.client.models.list()], ["eliza"])
        self.assertEqual(self.client.models.retrieve("eliza").id, "eliza")
        self.assertEqual(httpx.get(BASE + "/healthz").json(), {"status": "ok"})
        for headers in ({}, {"Authorization": "Bearer wrong"}):
            response = httpx.get(BASE + "/v1/models", headers=headers)
            self.assertEqual(response.status_code, 401)
            self.assertEqual(response.json()["error"]["code"], "invalid_api_key")
        self.assertEqual(httpx.get(OPEN_BASE + "/v1/models").status_code, 200)
        response = httpx.post(OPEN_BASE + "/v1/chat/completions", json={
            "model": "eliza", "messages": [{"role": "user", "content": "hello"}]})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["choices"][0]["message"]["role"], "assistant")

    def test_memory_and_isolation(self):
        a = [{"role": "user", "content": "my bicycle is blue"}]
        a.append(self.completion(a).choices[0].message.model_dump(exclude_none=True))
        b = [{"role": "user", "content": "my boat is green"}]
        b.append(self.completion(b).choices[0].message.model_dump(exclude_none=True))
        # SDK adds no unsupported fields when dumping this text-only message.
        for history, own, other in ((a, "bicycle is blue", "boat"), (b, "boat is green", "bicycle")):
            history.append({"role": "user", "content": "zzzxxy"})
            reply = self.completion(history).choices[0].message.content
            self.assertIn(own, reply)
            self.assertNotIn(other, reply)
        fresh = self.completion([{"role": "user", "content": "zzzxxy"}]).choices[0].message.content
        self.assertNotIn("bicycle", fresh)
        self.assertNotIn("boat", fresh)

    def test_streaming_and_unicode(self):
        messages = [{"role": "user", "content": [
            {"type": "text", "text": "my café"}, {"type": "text", "text": " is beautiful"}]}]
        expected = self.completion(messages).choices[0].message.content
        self.assertIn("café", expected)
        for include_usage in (False, True):
            chunks = list(self.completion(messages, stream=True,
                                          stream_options={"include_usage": include_usage}))
            self.assertEqual(chunks[0].choices[0].delta.role, "assistant")
            self.assertEqual("".join(c.choices[0].delta.content or "" for c in chunks if c.choices), expected)
            self.assertEqual([c.choices[0].finish_reason for c in chunks if c.choices][-1], "stop")
            self.assertEqual(len({c.id for c in chunks}), 1)
            self.assertEqual(len({c.created for c in chunks}), 1)
            if include_usage:
                self.assertEqual(chunks[-1].choices, [])
                self.assertEqual(chunks[-1].usage.total_tokens, 0)
        raw = httpx.post(BASE + "/v1/chat/completions", headers=HEADERS,
                         json={"model": "eliza", "messages": messages, "stream": True})
        self.assertEqual(raw.status_code, 200)
        self.assertTrue(raw.headers["content-type"].startswith("text/event-stream"))
        self.assertTrue(raw.text.endswith("data: [DONE]\n\n"))
        events = [json.loads(line[6:]) for line in raw.text.splitlines()
                  if line.startswith("data: ") and line != "data: [DONE]"]
        self.assertEqual(events[1]["choices"][0]["delta"]["content"], expected)

    def test_validation_and_limits(self):
        base = {"model": "eliza", "messages": [{"role": "user", "content": "hello"}]}
        for patch, expected in (
            ({"model": "missing"}, 404), ({"messages": []}, 400),
            ({"tools": []}, 400), ({"n": 2}, 400), ({"seed": 0}, 400),
            ({"messages": [{"role": "user", "content": ""}]}, 400),
            ({"messages": [{"role": "user", "content": [{"type": "image_url", "image_url": {"url": "x"}}]}]}, 400),
            ({"messages": base["messages"] * 257}, 400),
            ({"messages": [{"role": "user", "content": "x" * 1048576}]}, 413),
        ):
            with self.subTest(patch=list(patch), expected=expected):
                response = httpx.post(BASE + "/v1/chat/completions", headers=HEADERS,
                                      json=base | patch, timeout=10)
                self.assertEqual(response.status_code, expected, response.text[:200])
                self.assertIn("error", response.json())
        response = httpx.post(BASE + "/v1/chat/completions",
                              headers=HEADERS | {"Content-Type": "application/json"}, content="{broken")
        self.assertEqual(response.status_code, 400)
        self.assertIn("error", response.json())

    def test_replay_concurrency_and_restart(self):
        snapshots = []
        for seed in (1, 42, 2147483646):
            history = [{"role": "system", "content": "You are a different assistant."}]
            replies = []
            fingerprints = []
            for turn in TURNS:
                history.append({"role": "user", "content": turn})
                reply = self.completion(history, seed=seed)
                replies.append(reply.choices[0].message.content)
                fingerprints.append(reply.system_fingerprint)
                history.append({"role": "assistant", "content": replies[-1]})
            final_request = history[:-1]
            with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
                repeated = list(pool.map(lambda _: self.completion(final_request, seed=seed).choices[0].message.content, range(12)))
            self.assertEqual(repeated, [replies[-1]] * 12)
            snapshots.append({"seed": seed, "replies": replies, "fingerprints": fingerprints})
        path = Path("/results/transcripts.json")
        if MODE == "before":
            path.write_text(json.dumps(snapshots, ensure_ascii=False), encoding="utf-8")
        elif MODE == "after":
            self.assertEqual(snapshots, json.loads(path.read_text(encoding="utf-8")),
                             "every turn and fingerprint must match before restart")
        else:
            self.fail(f"Unknown mode: {MODE}")


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=2)
