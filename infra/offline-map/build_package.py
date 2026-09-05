#!/usr/bin/env python3
"""Build a deterministic, provider-neutral TerraLeb offline tile package."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import sys
import zipfile
from pathlib import Path

LEBANON = (35.094, 33.045, 36.645, 34.695)
TILE_PATTERN = re.compile(r"^(\d{1,2})/(\d+)/(\d+)\.tile$")
VERSION_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,49}$")
SCENE_PATTERN = re.compile(r"^[A-Za-z0-9._:-]{1,160}$")
REQUIRED_PROCESSING_FIELDS = {
    "cloud_shadow_filter",
    "mosaic_method",
    "clipping",
    "reprojection",
    "resampling",
    "tool_versions",
    "osm_extract",
}


def fail(message: str) -> None:
    raise ValueError(message)


def tile_range(zoom: int) -> tuple[int, int, int, int]:
    west, south, east, north = LEBANON
    scale = 2**zoom

    def lon_x(value: float) -> int:
        return math.floor(((value + 180) / 360) * scale)

    def lat_y(value: float) -> int:
        radians = math.radians(value)
        return math.floor(
            ((1 - math.log(math.tan(radians) + 1 / math.cos(radians)) / math.pi) / 2)
            * scale
        )

    return lon_x(west), lon_x(east), lat_y(north), lat_y(south)


def validate_manifest(raw: object) -> dict[str, object]:
    if not isinstance(raw, dict):
        fail("manifest must be a JSON object")
    manifest = raw
    if manifest.get("schema_version") != 1:
        fail("schema_version must be 1")
    version = manifest.get("package_version")
    if not isinstance(version, str) or not VERSION_PATTERN.fullmatch(version):
        fail("package_version is invalid")
    tile_count = manifest.get("tile_count")
    zoom_min = manifest.get("zoom_min")
    zoom_max = manifest.get("zoom_max")
    if not isinstance(tile_count, int) or isinstance(tile_count, bool) or tile_count < 1:
        fail("tile_count must be a positive integer")
    if (
        not isinstance(zoom_min, int)
        or isinstance(zoom_min, bool)
        or not isinstance(zoom_max, int)
        or isinstance(zoom_max, bool)
        or zoom_min < 0
        or zoom_max > 18
        or zoom_max < zoom_min
    ):
        fail("zoom range is invalid")
    if manifest.get("tile_scheme") != "xyz":
        fail("tile_scheme must be xyz")
    if manifest.get("dataset_code") != "copernicus_sentinel2_osm_labels":
        fail("dataset_code is not approved for this package format")
    scene_ids = manifest.get("source_scene_ids")
    if (
        not isinstance(scene_ids, list)
        or not scene_ids
        or len(scene_ids) > 500
        or any(not isinstance(value, str) or not SCENE_PATTERN.fullmatch(value) for value in scene_ids)
    ):
        fail("source_scene_ids are invalid")
    for field in ("source_acquisition_start", "source_acquisition_end"):
        value = manifest.get(field)
        if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
            fail(f"{field} must be an ISO date")
    if manifest["source_acquisition_start"] > manifest["source_acquisition_end"]:
        fail("source acquisition dates are reversed")
    terms = manifest.get("source_terms_url")
    attribution = manifest.get("source_attribution")
    resolution = manifest.get("source_resolution_meters")
    if not isinstance(terms, str) or not terms.startswith("https://"):
        fail("source_terms_url must use HTTPS")
    if not isinstance(attribution, str) or len(attribution.strip()) < 10:
        fail("source_attribution is incomplete")
    if not isinstance(resolution, (int, float)) or isinstance(resolution, bool) or not 1 <= resolution <= 100:
        fail("source_resolution_meters is invalid")
    processing = manifest.get("processing_manifest")
    if not isinstance(processing, dict) or not REQUIRED_PROCESSING_FIELDS.issubset(processing):
        fail("processing_manifest is incomplete")
    if len(json.dumps(processing, separators=(",", ":"), ensure_ascii=False).encode()) > 65536:
        fail("processing_manifest is too large")
    return manifest


def valid_image_header(path: Path) -> bool:
    with path.open("rb") as handle:
        header = handle.read(12)
    return (
        header.startswith(b"\x89PNG\r\n\x1a\n")
        or header.startswith(b"\xff\xd8\xff")
        or (len(header) >= 12 and header[:4] == b"RIFF" and header[8:12] == b"WEBP")
    )


def collect_tiles(root: Path, manifest: dict[str, object]) -> list[tuple[str, Path]]:
    if not root.is_dir() or root.is_symlink():
        fail("tiles directory must be a real directory")
    tiles: list[tuple[str, Path]] = []
    for candidate in root.rglob("*"):
        if candidate.is_symlink():
            fail(f"symbolic links are not allowed: {candidate}")
        if not candidate.is_file():
            continue
        relative = candidate.relative_to(root).as_posix()
        match = TILE_PATTERN.fullmatch(relative)
        if not match:
            fail(f"unexpected file in tile tree: {relative}")
        zoom, x, y = map(int, match.groups())
        if not manifest["zoom_min"] <= zoom <= manifest["zoom_max"]:
            fail(f"tile outside declared zoom range: {relative}")
        min_x, max_x, min_y, max_y = tile_range(zoom)
        if not min_x <= x <= max_x or not min_y <= y <= max_y:
            fail(f"tile outside Lebanon bounds: {relative}")
        size = candidate.stat().st_size
        if size < 8 or size > 5 * 1024 * 1024 or not valid_image_header(candidate):
            fail(f"invalid tile image: {relative}")
        tiles.append((relative, candidate))
    tiles.sort(key=lambda item: item[0])
    if len(tiles) != manifest["tile_count"]:
        fail(f"tile_count mismatch: manifest={manifest['tile_count']} actual={len(tiles)}")
    return tiles


def add_file(archive: zipfile.ZipFile, name: str, contents: bytes) -> None:
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 3
    info.external_attr = 0o100644 << 16
    archive.writestr(info, contents, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tiles", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.output.exists():
        fail("output already exists; choose a new path")
    manifest = validate_manifest(json.loads(args.manifest.read_text(encoding="utf-8")))
    tiles = collect_tiles(args.tiles.resolve(), manifest)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    normalized_manifest = (json.dumps(manifest, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
    with zipfile.ZipFile(args.output, "x", allowZip64=True) as archive:
        add_file(archive, "manifest.json", normalized_manifest)
        for relative, source in tiles:
            add_file(archive, f"tiles/{relative}", source.read_bytes())
    evidence = {
        "schemaVersion": 1,
        "packageVersion": manifest["package_version"],
        "path": str(args.output.resolve()),
        "bytes": args.output.stat().st_size,
        "sha256": sha256_file(args.output),
        "tileCount": len(tiles),
        "sourceSceneCount": len(manifest["source_scene_ids"]),
        "deterministicZipMetadata": True,
    }
    print(json.dumps(evidence, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"Offline package build failed: {error}", file=sys.stderr)
        raise SystemExit(1)
