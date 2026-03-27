#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path
from typing import Optional

VERSION_MANIFEST_URL = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"


def _default_minecraft_dir() -> Path:
    home = Path.home()
    if sys.platform.startswith("darwin"):
        return home / "Library" / "Application Support" / "minecraft"
    if sys.platform.startswith("win"):
        appdata = os.environ.get("APPDATA")
        if appdata:
            return Path(appdata) / ".minecraft"
        return home / ".minecraft"
    return home / ".minecraft"


def _download_json(url: str) -> dict:
    with urllib.request.urlopen(url) as response:
        return json.loads(response.read().decode("utf-8"))


def _download_file(url: str, dest: Path) -> None:
    with urllib.request.urlopen(url) as response, dest.open("wb") as f:
        shutil.copyfileobj(response, f)


def _sha1_file(path: Path) -> str:
    sha1 = hashlib.sha1()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            sha1.update(chunk)
    return sha1.hexdigest()


def _find_version_entry(manifest: dict, version: str) -> dict:
    for entry in manifest.get("versions", []):
        if entry.get("id") == version:
            return entry
    raise ValueError(f"Version {version} not found in manifest.")


def _resolve_local_jar(minecraft_dir: Path, version: str) -> Optional[Path]:
    jar_path = minecraft_dir / "versions" / version / f"{version}.jar"
    if jar_path.is_file():
        return jar_path
    return None


def _safe_extract_datapack(jar_path: Path, dest_dir: Path) -> None:
    with zipfile.ZipFile(jar_path) as zf:
        members = [
            name
            for name in zf.namelist()
            if name == "pack.mcmeta"
            or name == "pack.png"
            or name.startswith("data/")
        ]

        for name in members:
            # Prevent zip-slip and absolute paths.
            parts = Path(name).parts
            if any(part == ".." for part in parts):
                raise ValueError(f"Unsafe path in zip entry: {name}")
            if name.startswith("/") or name.startswith("\\"):
                raise ValueError(f"Unsafe absolute path in zip entry: {name}")

            target_path = dest_dir / name
            target_path.parent.mkdir(parents=True, exist_ok=True)
            if name.endswith("/"):
                target_path.mkdir(parents=True, exist_ok=True)
                continue

            with zf.open(name) as src, target_path.open("wb") as dst:
                shutil.copyfileobj(src, dst)


def extract_vanilla_datapack(
    version: str,
    dest_dir: Path,
    jar_path: Optional[Path],
    minecraft_dir: Path,
    download_kind: str,
    force: bool,
) -> None:
    if dest_dir.exists():
        if any(dest_dir.iterdir()) and not force:
            raise FileExistsError(
                f"Destination {dest_dir} is not empty. Use --force to overwrite."
            )
        if force:
            shutil.rmtree(dest_dir)
    dest_dir.mkdir(parents=True, exist_ok=True)

    if jar_path is None:
        jar_path = _resolve_local_jar(minecraft_dir, version)

    if jar_path is None:
        manifest = _download_json(VERSION_MANIFEST_URL)
        version_entry = _find_version_entry(manifest, version)
        version_json = _download_json(version_entry["url"])
        downloads = version_json.get("downloads", {})
        if download_kind not in downloads:
            raise ValueError(
                f"Download kind '{download_kind}' not available for {version}."
            )
        download = downloads[download_kind]
        url = download["url"]
        expected_sha1 = download.get("sha1")

        with tempfile.TemporaryDirectory() as tmpdir:
            tmp_path = Path(tmpdir) / f"{version}-{download_kind}.jar"
            _download_file(url, tmp_path)
            if expected_sha1:
                actual_sha1 = _sha1_file(tmp_path)
                if actual_sha1.lower() != expected_sha1.lower():
                    raise ValueError(
                        "SHA1 mismatch for downloaded jar. "
                        f"Expected {expected_sha1}, got {actual_sha1}."
                    )
            _safe_extract_datapack(tmp_path, dest_dir)
            return

    if not jar_path.is_file():
        raise FileNotFoundError(f"Jar not found: {jar_path}")
    _safe_extract_datapack(jar_path, dest_dir)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Extract the vanilla datapack from a Minecraft 1.21.11 jar."
    )
    parser.add_argument(
        "--version",
        default="1.21.11",
        help="Minecraft version to extract (default: 1.21.11).",
    )
    parser.add_argument(
        "--dest",
        type=Path,
        default=Path("vanilla/1.21.11"),
        help="Destination directory for the datapack.",
    )
    parser.add_argument(
        "--jar",
        type=Path,
        help="Path to a local Minecraft client/server jar.",
    )
    parser.add_argument(
        "--minecraft-dir",
        type=Path,
        default=None,
        help="Minecraft directory (defaults to OS-specific location).",
    )
    parser.add_argument(
        "--download-kind",
        choices=["client", "server"],
        default="client",
        help="Which jar to download if no local jar is found.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite destination directory if it exists.",
    )
    args = parser.parse_args()

    minecraft_dir = args.minecraft_dir or _default_minecraft_dir()
    extract_vanilla_datapack(
        version=args.version,
        dest_dir=args.dest,
        jar_path=args.jar,
        minecraft_dir=minecraft_dir,
        download_kind=args.download_kind,
        force=args.force,
    )

    print(f"Extracted vanilla datapack for {args.version} to {args.dest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
