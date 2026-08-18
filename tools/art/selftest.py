#!/usr/bin/env python3
"""
selftest.py — exercises tools/art/generate.py's live path with a stubbed
transport, so the harness is proven before a paid key ever exists.

    uv run --project tools/art tools/art/selftest.py

Covers: size normalisation, request hashing, the success path (PNG written,
manifest written, real pixel dimensions measured), the cache (second run makes
zero calls), --force, the safety-block response shape, prompt-level blockReason,
text-only responses, 429 backoff, and the missing-key failure mode. No network,
no API key, nothing billed.
"""

from __future__ import annotations

import io
import json
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import generate  # noqa: E402
from PIL import Image  # noqa: E402

PASS = 0
FAIL = 0


def check(name: str, condition: bool, detail: str = "") -> None:
    global PASS, FAIL
    if condition:
        PASS += 1
        print(f"  ok   {name}")
    else:
        FAIL += 1
        print(f"  FAIL {name}  {detail}")


def png_bytes(width: int, height: int) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (width, height), (0, 255, 0)).save(buf, format="PNG")
    return buf.getvalue()


class StubResponse:
    def __init__(self, status: int, payload: dict | None, text: str = "",
                 headers: dict | None = None):
        self.status_code = status
        self._payload = payload
        self.text = text if payload is None else json.dumps(payload)
        self.headers = headers or {}

    def json(self):
        if self._payload is None:
            raise ValueError("not json")
        return self._payload


class StubSession:
    """Replays a scripted list of responses and records every request."""

    def __init__(self, script: list[StubResponse]):
        self.script = list(script)
        self.calls: list[dict] = []

    def post(self, url, headers=None, json=None, timeout=None):  # noqa: A002
        self.calls.append({"url": url, "headers": headers, "body": json, "timeout": timeout})
        if not self.script:
            raise AssertionError("stub session ran out of scripted responses")
        return self.script.pop(0)


def ok_image_response(width: int = 64, height: int = 48) -> StubResponse:
    import base64
    return StubResponse(200, {
        "candidates": [{
            "content": {"parts": [
                {"text": "Here is the image."},
                {"inlineData": {"mimeType": "image/png",
                                "data": base64.b64encode(png_bytes(width, height)).decode()}},
            ]},
            "finishReason": "STOP",
        }]
    })


# ---------------------------------------------------------------------------

def test_size_normalisation() -> None:
    print("size normalisation")
    cases = [
        ("1536x1152", ("4:3", "2K", (1536, 1152))),
        ("2048x2048", ("1:1", "2K", (2048, 2048))),
        ("512x512", ("1:1", "512px", (512, 512))),
        ("2K", ("1:1", "2K", None)),
        ("16:9", ("16:9", "2K", None)),
        (None, ("1:1", "2K", None)),
        ({"aspect_ratio": "3:4", "image_size": "1K"}, ("3:4", "1K", None)),
        ("1920x1080", ("16:9", "2K", (1920, 1080))),
        ("300x1200", ("1:4", "2K", (300, 1200))),
        ("5000x5000", ("1:1", "4K", (5000, 5000))),
    ]
    for raw, want in cases:
        got = generate.normalize_size(raw, "test")
        check(f"normalize_size({raw!r})", got == want, f"got {got}, want {want}")

    for bad in ("nonsense", "0:0", {"aspect_ratio": "7:5", "image_size": "2K"},
                {"aspect_ratio": "1:1", "image_size": "8K"}):
        try:
            generate.normalize_size(bad, "test")
            check(f"normalize_size({bad!r}) rejects", False, "no SpecError raised")
        except generate.SpecError:
            check(f"normalize_size({bad!r}) rejects", True)

    check("estimate_px 4:3 @ 2K", generate.estimate_px("4:3", "2K") == (2048, 1536))
    check("estimate_px 9:16 @ 1K", generate.estimate_px("9:16", "1K") == (576, 1024))


def test_env_parsing(tmp: Path) -> None:
    print("dotenv parsing")
    env = tmp / ".env"
    env.write_text(
        "# comment\n"
        "\n"
        "export GEMINI_API_KEY = AIza-from-file  # trailing note\n"
        "QUOTED='sq value'\n"
        'DQUOTED="dq value"\n'
        "MALFORMED\n",
        encoding="utf-8",
    )
    parsed = generate.parse_env_file(env)
    check("export prefix + inline comment stripped",
          parsed.get("GEMINI_API_KEY") == "AIza-from-file", repr(parsed.get("GEMINI_API_KEY")))
    check("single quotes stripped", parsed.get("QUOTED") == "sq value")
    check("double quotes stripped", parsed.get("DQUOTED") == "dq value")
    check("malformed line ignored", "MALFORMED" not in parsed)
    key, source = generate.resolve_api_key(env)
    check("resolve_api_key reads .env", key == "AIza-from-file" and str(env) in source, source)
    check("resolve_api_key on missing file", generate.resolve_api_key(tmp / "nope.env")[0] is None)


def test_spec_loading(tmp: Path) -> None:
    print("spec loading")
    prompts = tmp / "prompts"
    prompts.mkdir(parents=True, exist_ok=True)
    (prompts / "grp.json").write_text(json.dumps({
        "defaults": {"prompt_prefix": "PRE", "prompt_suffix": "POST", "size": "1K"},
        "prompts": [
            {"name": "a", "prompt": "body-a"},
            {"name": "b", "prompt": "body-b", "size": "1536x1152", "variants": 2,
             "model": "gemini-3.1-flash-image", "seed": 7},
        ],
    }), encoding="utf-8")
    specs = generate.load_group("grp", prompts, None)
    check("two entries loaded", len(specs) == 2)
    check("prefix/suffix joined verbatim", specs[0].prompt == "PRE\n\nbody-a\n\nPOST",
          repr(specs[0].prompt))
    check("default size inherited", (specs[0].aspect_ratio, specs[0].image_size) == ("1:1", "1K"))
    check("per-entry size wins", (specs[1].aspect_ratio, specs[1].image_size) == ("4:3", "2K"))
    check("per-entry model wins", specs[1].model == "gemini-3.1-flash-image")
    check("seed carried", specs[1].seed == 7)

    overridden = generate.load_group("grp", prompts, "gemini-2.5-flash-image")
    check("--model beats per-entry model",
          all(s.model == "gemini-2.5-flash-image" for s in overridden))

    body = generate.build_request_body(specs[1])
    check("seed reaches generationConfig", body["generationConfig"].get("seed") == 7)
    check("responseModalities present",
          body["generationConfig"]["responseModalities"] == ["TEXT", "IMAGE"])
    check("imageConfig present",
          body["generationConfig"]["imageConfig"] == {"aspectRatio": "4:3", "imageSize": "2K"})
    check("no seed key when unset", "seed" not in generate.build_request_body(specs[0])["generationConfig"])

    sha_a = generate.request_sha256(specs[0].model, generate.build_request_body(specs[0]))
    sha_b = generate.request_sha256(specs[1].model, generate.build_request_body(specs[1]))
    check("hashes differ per entry", sha_a != sha_b)
    check("hash is stable",
          sha_a == generate.request_sha256(specs[0].model, generate.build_request_body(specs[0])))
    check("hash covers the model id",
          sha_a != generate.request_sha256("gemini-3.1-flash-image",
                                           generate.build_request_body(specs[0])))

    # bare list form
    (prompts / "bare.json").write_text(json.dumps(
        [{"name": "solo", "prompt": "x", "size": "512px"}]), encoding="utf-8")
    bare = generate.load_group("bare", prompts, None)
    check("bare list form loads", len(bare) == 1 and bare[0].image_size == "512px")

    for bad, why in [
        ([{"prompt": "x"}], "missing name"),
        ([{"name": "a", "prompt": "x"}, {"name": "a", "prompt": "y"}], "duplicate name"),
        ([{"name": "a/b", "prompt": "x"}], "unsafe name"),
        ([{"name": "a", "prompt": ""}], "empty prompt"),
        ([{"name": "a", "prompt": "x", "variants": 0}], "variants < 1"),
        ([], "no entries"),
    ]:
        (prompts / "bad.json").write_text(json.dumps(bad), encoding="utf-8")
        try:
            generate.load_group("bad", prompts, None)
            check(f"rejects {why}", False, "no SpecError raised")
        except generate.SpecError:
            check(f"rejects {why}", True)


def test_extract_image() -> None:
    print("response parsing")
    mime, raw, finish, text = generate.extract_image(ok_image_response(32, 16).json())
    check("image extracted", mime == "image/png" and raw[:8] == b"\x89PNG\r\n\x1a\n")
    check("finishReason surfaced", finish == "STOP")
    check("accompanying text surfaced", text == "Here is the image.")

    blocked_prompt = {"promptFeedback": {"blockReason": "SAFETY", "safetyRatings": [
        {"category": "HARM_CATEGORY_DANGEROUS_CONTENT", "probability": "HIGH", "blocked": True}]}}
    try:
        generate.extract_image(blocked_prompt)
        check("prompt-level blockReason raises", False)
    except generate.SafetyBlocked as exc:
        check("prompt-level blockReason raises", exc.reason == "SAFETY")
        check("blocked rating named in detail", "DANGEROUS_CONTENT" in exc.detail, exc.detail)

    blocked_image = {"candidates": [{"content": {"parts": [{"text": "I can't make that."}]},
                                     "finishReason": "IMAGE_SAFETY",
                                     "safetyRatings": [{"category": "HARM_CATEGORY_VIOLENCE",
                                                        "probability": "MEDIUM"}]}]}
    try:
        generate.extract_image(blocked_image)
        check("candidate-level IMAGE_SAFETY raises", False)
    except generate.SafetyBlocked as exc:
        check("candidate-level IMAGE_SAFETY raises", exc.reason == "IMAGE_SAFETY")

    text_only = {"candidates": [{"content": {"parts": [{"text": "here is a description instead"}]},
                                 "finishReason": "STOP"}]}
    try:
        generate.extract_image(text_only)
        check("text-only response raises NoImageReturned", False)
    except generate.NoImageReturned as exc:
        check("text-only response raises NoImageReturned",
              "description" in exc.text)

    try:
        generate.extract_image({"candidates": []})
        check("empty candidates raises", False)
    except generate.NoImageReturned:
        check("empty candidates raises", True)

    snake = {"candidates": [{"content": {"parts": [
        {"inline_data": {"mime_type": "image/png",
                         "data": __import__("base64").b64encode(png_bytes(8, 8)).decode()}}]},
        "finishReason": "STOP"}]}
    check("snake_case inline_data accepted", generate.extract_image(snake)[0] == "image/png")


def test_backoff() -> None:
    print("rate-limit backoff")
    import random
    slept: list[float] = []
    real_sleep = generate.time.sleep
    generate.time.sleep = lambda s: slept.append(s)  # type: ignore[assignment]
    try:
        session = StubSession([
            StubResponse(429, {"error": {"code": 429, "message": "quota", "status": "RESOURCE_EXHAUSTED",
                                         "details": [{"@type": "type.googleapis.com/google.rpc.RetryInfo",
                                                      "retryDelay": "13s"}]}}),
            StubResponse(503, {"error": {"code": 503, "message": "overloaded"}},
                         headers={"Retry-After": "2"}),
            ok_image_response(),
        ])
        out = generate.call_api(session, "m", {"contents": []}, "k", timeout=1,
                                max_retries=5, label="t", rng=random.Random(1))
        check("retried through 429 then 503", len(session.calls) == 3)
        check("honoured RetryInfo retryDelay 13s", 13.0 <= slept[0] < 14.0, str(slept))
        check("honoured Retry-After header 2s", 2.0 <= slept[1] < 3.0, str(slept))
        check("succeeded after retries", "candidates" in out)

        session = StubSession([StubResponse(403, {"error": {"message": "API key not valid"}})])
        try:
            generate.call_api(session, "m", {}, "k", timeout=1, max_retries=3,
                              label="t", rng=random.Random(1))
            check("403 not retried", False)
        except generate.ApiError as exc:
            check("403 not retried", exc.status == 403 and len(session.calls) == 1)
            check("403 message mentions the key", "GEMINI_API_KEY" in str(exc))

        session = StubSession([StubResponse(404, {"error": {"message": "not found"}})])
        try:
            generate.call_api(session, "typo-model", {}, "k", timeout=1, max_retries=3,
                              label="t", rng=random.Random(1))
            check("404 names known models", False)
        except generate.ApiError as exc:
            check("404 names known models", "gemini-3-pro-image" in str(exc))

        session = StubSession([StubResponse(429, {"error": {"message": "quota"}})] * 3)
        try:
            generate.call_api(session, "m", {}, "k", timeout=1, max_retries=2,
                              label="t", rng=random.Random(1))
            check("gives up after max-retries", False)
        except generate.ApiError as exc:
            check("gives up after max-retries", exc.status == 429 and len(session.calls) == 3)
    finally:
        generate.time.sleep = real_sleep  # type: ignore[assignment]


def test_end_to_end(tmp: Path) -> None:
    print("end to end (stubbed transport)")
    prompts = tmp / "prompts"
    prompts.mkdir(parents=True, exist_ok=True)
    out_root = tmp / "raw"
    (prompts / "pilot.json").write_text(json.dumps({
        "defaults": {"size": "512x512"},
        "prompts": [
            {"name": "carrier", "prompt": "a carrier"},
            {"name": "rock", "prompt": "a rock", "variants": 2},
        ],
    }), encoding="utf-8")

    import random
    real_sleep = generate.time.sleep
    generate.time.sleep = lambda s: None  # type: ignore[assignment]
    sessions: list[StubSession] = []
    real_requests_import = None

    def run(extra_argv: list[str], script: list[StubResponse]) -> int:
        session = StubSession(script)
        sessions.append(session)
        original_main = generate.main
        # Patch the session factory by swapping requests.Session for the stub.
        import types
        stub_requests = types.SimpleNamespace(Session=lambda: session)
        sys.modules["requests"] = stub_requests  # type: ignore[assignment]
        try:
            return original_main(["pilot", "--backend", "gemini",
                                  "--out-dir", str(out_root),
                                  "--prompts-dir", str(prompts),
                                  "--env-file", str(tmp / "fake.env")] + extra_argv)
        finally:
            sys.modules.pop("requests", None)

    (tmp / "fake.env").write_text("GEMINI_API_KEY=test-key-not-real\n", encoding="utf-8")

    try:
        rc = run([], [ok_image_response(64, 64), ok_image_response(64, 64), ok_image_response(64, 64)])
        check("first run exits 0", rc == 0, f"rc={rc}")
        calls = sessions[-1].calls
        check("3 API calls made", len(calls) == 3, str(len(calls)))
        if calls:
            check("api key sent as x-goog-api-key header",
                  calls[0]["headers"]["x-goog-api-key"] == "test-key-not-real")
            check("endpoint is generateContent",
                  calls[0]["url"].endswith(":generateContent"))
        else:
            check("api key sent as x-goog-api-key header", False, "no calls made")
            check("endpoint is generateContent", False, "no calls made")

        carrier = out_root / "pilot" / "carrier.png"
        rock1 = out_root / "pilot" / "rock-01.png"
        rock2 = out_root / "pilot" / "rock-02.png"
        check("single-variant file is <name>.png", carrier.exists())
        check("multi-variant files are <name>-NN.png", rock1.exists() and rock2.exists())
        check("written file is a real PNG", carrier.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n")

        manifest = json.loads((out_root / "pilot" / "_manifest.json").read_text())
        entry = manifest["entries"]["carrier.png"]
        check("manifest records true pixel size", entry["actual_px"] == [64, 64], str(entry["actual_px"]))
        check("manifest records requested px", entry["requested_px"] == [512, 512])
        check("manifest records the request hash", len(entry["request_sha256"]) == 64)
        check("manifest records the prompt", entry["prompt"] == "a carrier")
        check("manifest records variant numbering",
              manifest["entries"]["rock-02.png"]["variant"] == 2)

        rc = run([], [])  # no scripted responses: any call would raise
        check("second run is fully cached, zero calls",
              rc == 0 and len(sessions[-1].calls) == 0, f"rc={rc}, calls={len(sessions[-1].calls)}")

        rc = run(["--force"], [ok_image_response(32, 32)] * 3)
        check("--force re-calls", rc == 0 and len(sessions[-1].calls) == 3)

        rc = run(["--only", "carrier"], [])
        check("--only + cache makes no call", rc == 0 and len(sessions[-1].calls) == 0)

        # Editing the prompt must invalidate exactly that entry.
        spec = json.loads((prompts / "pilot.json").read_text())
        spec["prompts"][0]["prompt"] = "a carrier, revised"
        (prompts / "pilot.json").write_text(json.dumps(spec), encoding="utf-8")
        rc = run([], [ok_image_response(32, 32)])
        check("edited prompt invalidates only that entry",
              rc == 0 and len(sessions[-1].calls) == 1, f"calls={len(sessions[-1].calls)}")

        # Safety block: non-zero exit, nothing cached.
        spec["prompts"][0]["prompt"] = "something the model refuses"
        (prompts / "pilot.json").write_text(json.dumps(spec), encoding="utf-8")
        rc = run([], [StubResponse(200, {"promptFeedback": {"blockReason": "PROHIBITED_CONTENT"}})])
        check("safety block exits 3", rc == generate.EXIT_BLOCKED, f"rc={rc}")

        rc = run(["--keep-going"],
                 [StubResponse(200, {"promptFeedback": {"blockReason": "PROHIBITED_CONTENT"}})])
        check("--keep-going still exits non-zero at the end", rc == generate.EXIT_BLOCKED)

        # JPEG comes back -> converted to PNG, loudly.
        import base64
        jpeg_buf = io.BytesIO()
        Image.new("RGB", (40, 40), (0, 255, 0)).save(jpeg_buf, format="JPEG")
        spec["prompts"][0]["prompt"] = "a carrier, jpeg path"
        (prompts / "pilot.json").write_text(json.dumps(spec), encoding="utf-8")
        rc = run([], [StubResponse(200, {"candidates": [{"content": {"parts": [
            {"inlineData": {"mimeType": "image/jpeg",
                            "data": base64.b64encode(jpeg_buf.getvalue()).decode()}}]},
            "finishReason": "STOP"}]})])
        check("jpeg response converted and saved as PNG",
              rc == 0 and carrier.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n")
        manifest = json.loads((out_root / "pilot" / "_manifest.json").read_text())
        check("manifest records the source format",
              manifest["entries"]["carrier.png"]["source_format"] == "JPEG")
    finally:
        generate.time.sleep = real_sleep  # type: ignore[assignment]
        del real_requests_import


def test_missing_key(tmp: Path) -> None:
    print("missing key")
    prompts = tmp / "prompts"
    (prompts / "nokey.json").write_text(json.dumps(
        [{"name": "x", "prompt": "y"}]), encoding="utf-8")
    import os
    saved = {k: os.environ.pop(k, None) for k in
             ("GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENAI_API_KEY")}
    try:
        # The no-key contract is Gemini's alone: the local backend needs no
        # key at all (and would really generate here if left on the default).
        rc = generate.main(["nokey", "--backend", "gemini",
                            "--prompts-dir", str(prompts),
                            "--out-dir", str(tmp / "raw"),
                            "--env-file", str(tmp / "absent.env")])
        check("gemini live run with no key exits 5",
              rc == generate.EXIT_NO_KEY, f"rc={rc}")
        rc = generate.main(["nokey", "--dry-run", "--prompts-dir", str(prompts),
                            "--out-dir", str(tmp / "raw"),
                            "--env-file", str(tmp / "absent.env")])
        check("dry run with no key exits 0", rc == 0, f"rc={rc}")
        rc = generate.main(["does-not-exist", "--dry-run", "--prompts-dir", str(prompts),
                            "--out-dir", str(tmp / "raw")])
        check("unknown group exits 2", rc == generate.EXIT_USAGE, f"rc={rc}")
    finally:
        for key, value in saved.items():
            if value is not None:
                os.environ[key] = value


def main() -> int:
    tmp = Path(tempfile.mkdtemp(prefix="zs-art-selftest-"))
    try:
        test_size_normalisation()
        test_env_parsing(tmp)
        test_spec_loading(tmp)
        test_extract_image()
        test_backoff()
        test_end_to_end(tmp)
        test_missing_key(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print()
    print(f"{PASS} passed, {FAIL} failed")
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
