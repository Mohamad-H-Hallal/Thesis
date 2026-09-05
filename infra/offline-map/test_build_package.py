import importlib.util
import json
import tempfile
import unittest
import zipfile
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("build_package.py")
SPEC = importlib.util.spec_from_file_location("terraleb_offline_builder", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
BUILDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)


def manifest() -> dict[str, object]:
    return {
        "schema_version": 1,
        "package_version": "lebanon-s2-2026-08-v1",
        "tile_count": 1,
        "zoom_min": 7,
        "zoom_max": 7,
        "tile_scheme": "xyz",
        "dataset_code": "copernicus_sentinel2_osm_labels",
        "source_acquisition_start": "2026-07-01",
        "source_acquisition_end": "2026-07-31",
        "source_scene_ids": ["S2A_MSIL2A_20260701T081611_N0609_R121"],
        "source_terms_url": "https://dataspace.copernicus.eu/terms-and-conditions",
        "source_attribution": "Contains modified Copernicus Sentinel-2 and OpenStreetMap data.",
        "source_resolution_meters": 10,
        "processing_manifest": {
            "cloud_shadow_filter": "SCL cloud and shadow classes removed",
            "mosaic_method": "latest clear pixel",
            "clipping": "Lebanon boundary version 2026-08",
            "reprojection": "EPSG:3857",
            "resampling": "bilinear imagery; nearest labels",
            "tool_versions": {"gdal": "3.10.0", "renderer": "1.0.0"},
            "osm_extract": {
                "provider": "reviewed extract provider",
                "downloaded_at": "2026-08-26T00:00:00Z",
                "sha256": "a" * 64,
                "terms_url": "https://www.openstreetmap.org/copyright",
            },
        },
    }


class OfflinePackageBuilderTests(unittest.TestCase):
    def test_build_is_deterministic_and_uses_expected_layout(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tiles = root / "tiles" / "7" / "76"
            tiles.mkdir(parents=True)
            (tiles / "51.tile").write_bytes(b"\x89PNG\r\n\x1a\n")
            package_manifest = manifest()
            validated = BUILDER.validate_manifest(package_manifest)
            collected = BUILDER.collect_tiles(root / "tiles", validated)
            outputs = [root / "first.zip", root / "second.zip"]
            normalized = (
                json.dumps(
                    validated,
                    sort_keys=True,
                    separators=(",", ":"),
                    ensure_ascii=False,
                )
                + "\n"
            ).encode()
            for output in outputs:
                with zipfile.ZipFile(output, "x", allowZip64=True) as archive:
                    BUILDER.add_file(archive, "manifest.json", normalized)
                    for relative, source in collected:
                        BUILDER.add_file(
                            archive,
                            f"tiles/{relative}",
                            source.read_bytes(),
                        )
            self.assertEqual(
                BUILDER.sha256_file(outputs[0]), BUILDER.sha256_file(outputs[1])
            )
            with zipfile.ZipFile(outputs[0]) as archive:
                self.assertEqual(
                    archive.namelist(), ["manifest.json", "tiles/7/76/51.tile"]
                )

    def test_rejects_tiles_outside_lebanon_and_missing_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tile = root / "7" / "1"
            tile.mkdir(parents=True)
            (tile / "1.tile").write_bytes(b"\x89PNG\r\n\x1a\n")
            validated = BUILDER.validate_manifest(manifest())
            with self.assertRaisesRegex(ValueError, "outside Lebanon bounds"):
                BUILDER.collect_tiles(root, validated)

            incomplete = manifest()
            processing = dict(incomplete["processing_manifest"])
            processing.pop("osm_extract")
            incomplete["processing_manifest"] = processing
            with self.assertRaisesRegex(ValueError, "incomplete"):
                BUILDER.validate_manifest(incomplete)


if __name__ == "__main__":
    unittest.main()
