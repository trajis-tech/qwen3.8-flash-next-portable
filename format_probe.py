"""Measure how strictly the running server follows output formats.

Run it against the gateway (or Strata directly) after the model is loaded:

    python format_probe.py --temps 0.3,0.7,1.0 --trials 5

Each probe asks for an exact format and checks it mechanically.  The result
is a pass-rate table per temperature, so the question "is the temperature too
high?" is answered with numbers instead of a guess.  Standard library only.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from typing import Any, Callable

JSON_PROMPT = (
    "Return ONLY a JSON object with exactly these keys: "
    '"name" (string), "age" (integer), "tags" (array of strings). '
    "Use any plausible values. No prose, no code fences."
)
SCHEMA = {
    "type": "object",
    "properties": {
        "name": {"type": "string"},
        "age": {"type": "integer"},
        "tags": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["name", "age", "tags"],
    "additionalProperties": False,
}
TOOLS = [{
    "type": "function",
    "function": {
        "name": "get_weather",
        "description": "Get the current weather for a city",
        "parameters": {
            "type": "object",
            "properties": {"city": {"type": "string"}, "unit": {"type": "string", "enum": ["c", "f"]}},
            "required": ["city", "unit"],
        },
    },
}]


def check_json_object(text: str) -> str | None:
    try:
        value = json.loads(text.strip())
    except json.JSONDecodeError as exc:
        return f"not pure JSON ({exc.msg})"
    if not isinstance(value, dict) or set(value) != {"name", "age", "tags"}:
        return "wrong keys"
    if not isinstance(value["name"], str) or type(value["age"]) is not int or not isinstance(value["tags"], list):
        return "wrong types"
    return None


def check_exact_ok(text: str) -> str | None:
    return None if text.strip() == "OK" else f"got {text.strip()[:40]!r}"


def check_three_lines(text: str) -> str | None:
    lines = [line for line in text.strip().splitlines() if line.strip()]
    ok = len(lines) == 3 and all(re.fullmatch(rf"{i}\. [A-Za-z]+", line.strip()) for i, line in enumerate(lines, 1))
    return None if ok else f"got {len(lines)} lines"


PROBES: list[dict[str, Any]] = [
    {"name": "json-prompt-only", "messages": JSON_PROMPT, "check": check_json_object},
    {"name": "json-schema", "messages": JSON_PROMPT, "check": check_json_object,
     "extra": {"response_format": {"type": "json_schema", "json_schema": {"name": "person", "schema": SCHEMA, "strict": True}}}},
    {"name": "exact-OK", "messages": "Reply with exactly the two letters OK and nothing else.", "check": check_exact_ok},
    {"name": "three-lines", "messages": "Output exactly 3 lines, formatted as '1. word', '2. word', '3. word', each word a single English fruit name. Nothing else.", "check": check_three_lines},
    {"name": "tool-call", "messages": "What's the weather in Taipei in celsius? Use the tool.", "check": None,
     "extra": {"tools": TOOLS, "tool_choice": "auto"}},
]


def post(url: str, key: str, body: dict[str, Any], timeout: float) -> dict[str, Any]:
    request = urllib.request.Request(
        url, data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def run_probe(args: argparse.Namespace, probe: dict[str, Any], temperature: float) -> str | None:
    """Return None on pass, otherwise a short failure reason."""
    body: dict[str, Any] = {
        "model": args.model,
        "messages": [{"role": "user", "content": probe["messages"]}],
        "temperature": temperature,
        "max_tokens": args.max_tokens,
        **probe.get("extra", {}),
    }
    try:
        reply = post(args.base_url.rstrip("/") + "/chat/completions", args.api_key, body, args.timeout)
    except urllib.error.HTTPError as exc:
        return f"HTTP {exc.code}: {exc.read().decode('utf-8', 'replace')[:120]}"
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return f"request failed: {exc}"
    choice = reply["choices"][0]
    if choice.get("finish_reason") == "length":
        return "truncated (finish_reason=length; raise --max-tokens)"
    message = choice["message"]
    if probe["name"] == "tool-call":
        calls = message.get("tool_calls") or []
        if not calls:
            return "no tool call"
        try:
            arguments = json.loads(calls[0]["function"]["arguments"])
        except (KeyError, json.JSONDecodeError):
            return "tool arguments are not JSON"
        if calls[0]["function"].get("name") != "get_weather" or arguments.get("unit") not in ("c", "f") or not arguments.get("city"):
            return "wrong tool call"
        return None
    check: Callable[[str], str | None] = probe["check"]
    return check(message.get("content") or "")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-url", default="http://127.0.0.1:8000/v1")
    parser.add_argument("--api-key", default="local")
    parser.add_argument("--model", default="Qwen3.8-Flash-Next")
    parser.add_argument("--temps", default="0.3,0.7,1.0", help="comma-separated temperatures to compare")
    parser.add_argument("--trials", type=int, default=5)
    parser.add_argument("--max-tokens", type=int, default=4096, help="large enough that thinking does not truncate the answer")
    parser.add_argument("--timeout", type=float, default=600)
    parser.add_argument("--verbose", action="store_true", help="print each failure reason")
    args = parser.parse_args()

    temps = [float(t) for t in args.temps.split(",")]
    print(f"{'probe':<18}" + "".join(f"T={t:<6}" for t in temps))
    for probe in PROBES:
        cells = []
        for temperature in temps:
            reasons = [run_probe(args, probe, temperature) for _ in range(args.trials)]
            passed = sum(r is None for r in reasons)
            cells.append(f"{passed}/{args.trials}".ljust(8))
            if args.verbose:
                for reason in sorted({r for r in reasons if r}):
                    print(f"    [{probe['name']} T={temperature}] {reason}")
        print(f"{probe['name']:<18}" + "".join(cells), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
