#!/usr/bin/env python3
"""Reject QA fixture markers in production sources and linked Release executables."""
import argparse
import pathlib
import sys


# Keep QA banners in standalone harnesses outside production Sources, even in DEBUG.
MARKERS = ("ui fixture", "synthetic data", "synthetic-data")
ENCODINGS = ("utf-8", "utf-16-le", "utf-16-be")


def check_sources(sources):
    if not sources.is_dir():
        raise ValueError(f"Production source directory does not exist: {sources}")
    files = sorted(path for path in sources.rglob("*") if path.is_file())
    if not files:
        raise ValueError(f"Production source directory is empty: {sources}")
    for path in files:
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for marker in MARKERS:
                if marker in line.lower():
                    raise ValueError(f"Fixture chrome in production source: {path}:{number}: {marker!r}")


def check_binary(binary):
    # bytes.lower() folds ASCII only; all markers must remain ASCII. Short Swift
    # literals may not be contiguous bytes: the source check covers those markers.
    # Read the whole file to check every universal slice without executing it.
    data = binary.read_bytes().lower()
    if not data:
        raise ValueError("Release executable is empty")
    for marker in MARKERS:
        for encoding in ENCODINGS:
            if marker.encode(encoding) in data:
                raise ValueError(f"Fixture chrome in Release executable: {marker!r} ({encoding})")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=pathlib.Path, nargs="?")
    parser.add_argument("--sources", type=pathlib.Path, help="check all production source text, including DEBUG blocks")
    args = parser.parse_args()
    if args.binary is None and args.sources is None:
        parser.error("provide a Release executable and/or --sources directory")
    try:
        if args.sources is not None:
            check_sources(args.sources)
        if args.binary is not None:
            check_binary(args.binary)
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    print("Release fixture-chrome check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
