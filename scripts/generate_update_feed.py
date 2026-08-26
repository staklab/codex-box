#!/usr/bin/env python3
"""Render a canonical codex-box update feed from a JSON manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any


def load_manifest(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def compute_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalize_manifest(manifest: dict[str, Any], base_directory: Path) -> dict[str, Any]:
    release = manifest.get("release")
    if not isinstance(release, dict):
        raise SystemExit("manifest.release must be an object")

    artifacts = release.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        raise SystemExit("manifest.release.artifacts must be a non-empty array")

    normalized_artifacts: list[dict[str, Any]] = []
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            raise SystemExit("each artifact must be an object")

        normalized = dict(artifact)
        local_path = normalized.pop("localPath", None)
        sha256 = normalized.get("sha256")

        if not sha256 and local_path:
            candidate = (base_directory / local_path).resolve()
            if candidate.exists():
                normalized["sha256"] = compute_sha256(candidate)

        normalized_artifacts.append(normalized)

    release["artifacts"] = normalized_artifacts
    manifest["release"] = release
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Normalize codex-box release-feed JSON and compute sha256 from localPath when available."
    )
    parser.add_argument("input", help="input manifest JSON path")
    parser.add_argument("output", help="output feed JSON path")
    args = parser.parse_args()

    input_path = Path(args.input).resolve()
    output_path = Path(args.output).resolve()

    manifest = load_manifest(input_path)
    normalized = normalize_manifest(manifest, input_path.parent)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as handle:
        json.dump(normalized, handle, ensure_ascii=False, indent=2, sort_keys=False)
        handle.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
