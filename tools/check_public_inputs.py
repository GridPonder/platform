#!/usr/bin/env python3
"""Fail closed if a site build selects unreviewed content."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]


def verify(root: Path = ROOT, environ=None) -> None:
    environ = os.environ if environ is None else environ
    for key in ("GRIDPONDER_LEADERBOARD_DATA", "GRIDPONDER_STUDY_DATA"):
        if key in environ:
            raise ValueError(f"{key} is not supported by the public site")
    if (root / ".gitmodules").exists():
        raise ValueError("Submodules are outside the reviewed public inputs")
    if (root / "tools/benchmark/study-leaderboard.json").exists():
        raise ValueError("Keep generated study reports in their run directories")
    registry = json.loads((root / "tools/public-release-inputs.json").read_text())
    expected = registry["sha256"]
    pack_paths = {p.relative_to(root).as_posix() for p in (root / "packs").rglob("*")
                  if p.is_file() or p.is_symlink()}
    if pack_paths != {p for p in expected if p.startswith("packs/")}:
        raise ValueError("The public pack inventory changed; review the release inputs")
    for rel, digest in expected.items():
        path = root / rel
        if not path.is_file() or path.is_symlink():
            raise ValueError(f"Missing or linked public input: {rel}")
        # Reject linked parent directories as well as linked files.
        for parent in path.parents:
            if parent == root:
                break
            if parent.is_symlink():
                raise ValueError(f"Linked public input directory: {rel}")
        if not path.resolve().is_relative_to(root.resolve()):
            raise ValueError(f"Public input escapes its root: {rel}")
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError(f"Unreviewed public input: {rel}")


if __name__ == "__main__":
    try:
        verify()
    except (ValueError, KeyError, OSError) as exc:
        print(f"Public input check failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
    print("Reviewed public inputs verified.")
