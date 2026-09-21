#!/usr/bin/env python3
"""Compare committed fixtures with output from the pinned Swift Mac core."""

import json
import math
import pathlib
import sys


def load(path: str) -> dict:
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: verify_color_fixtures.py COMMITTED GENERATED", file=sys.stderr)
        return 2
    committed, generated = load(sys.argv[1]), load(sys.argv[2])
    for key in ("schemaVersion", "referenceCommit", "referenceFiles"):
        if committed.get(key) != generated.get(key):
            print(f"fixture metadata differs for {key}", file=sys.stderr)
            return 1
    expected_rows, actual_rows = committed.get("rows", []), generated.get("rows", [])
    if len(expected_rows) != 30 or len(actual_rows) != len(expected_rows):
        print("fixture row count differs", file=sys.stderr)
        return 1
    for index, (expected, actual) in enumerate(zip(expected_rows, actual_rows)):
        for key in ("warmth", "brightness"):
            if expected[key] != actual[key]:
                print(f"row {index} {key} differs", file=sys.stderr)
                return 1
        for key in ("gains", "matrixDiagonal"):
            if len(expected[key]) != 3 or len(actual[key]) != 3:
                print(f"row {index} {key} shape differs", file=sys.stderr)
                return 1
            for channel, (left, right) in enumerate(zip(expected[key], actual[key])):
                if not math.isfinite(left) or not math.isfinite(right) or abs(left - right) > 1e-7:
                    print(f"row {index} {key}[{channel}] differs: {left} != {right}", file=sys.stderr)
                    return 1
    print("30 color fixture rows match pinned Swift reference")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
