"""Adjust a Strata run config (strata-*.json) in place.

    strata_config.py CONFIG [--set KEY=JSON] [--set-str KEY=TEXT] [--unset KEY] [--move OLD NEW]

--set      sets a top-level key to a JSON literal (true, 4096, ...).
--set-str  sets a top-level key to a plain string (no JSON quoting, which
           PowerShell 5.1 mangles when passing arguments to native programs).
--unset    removes a top-level key.
--move     rewrites absolute paths after the portable folder was moved: every
           string containing OLD (any case, either slash style) gets NEW instead.
Strata's setup rewrites its own keys on reinstall, so the launcher re-applies
these on every start.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from typing import Any


def move_paths(value: Any, old: str, new: str) -> Any:
    if isinstance(value, str):
        for o, n in ((old, new), (old.replace("\\", "/"), new.replace("\\", "/"))):
            value = re.sub(re.escape(o), lambda _: n, value, flags=re.IGNORECASE)
        return value
    if isinstance(value, list):
        return [move_paths(item, old, new) for item in value]
    if isinstance(value, dict):
        return {key: move_paths(item, old, new) for key, item in value.items()}
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("config")
    parser.add_argument("--set", action="append", default=[], metavar="KEY=JSON")
    parser.add_argument("--set-str", action="append", default=[], metavar="KEY=TEXT")
    parser.add_argument("--unset", action="append", default=[], metavar="KEY")
    parser.add_argument("--move", nargs=2, metavar=("OLD", "NEW"))
    args = parser.parse_args()

    with open(args.config, encoding="utf-8") as fh:
        config = json.load(fh)
    before = json.dumps(config, sort_keys=True)
    if args.move:
        old, new = (os.path.normpath(p) for p in args.move)
        config = move_paths(config, old, new)
    for item in args.set:
        key, _, raw = item.partition("=")
        config[key] = json.loads(raw)
    for item in args.set_str:
        key, _, text = item.partition("=")
        config[key] = text
    for key in args.unset:
        config.pop(key, None)
    if json.dumps(config, sort_keys=True) != before:
        tmp = args.config + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(config, fh, ensure_ascii=False, indent=2)
        os.replace(tmp, args.config)
        print(f"-- updated {os.path.basename(args.config)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
