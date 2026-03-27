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


def _safe_extract_assets(jar_path: Path, dest_dir: Path) -> None:
    with zipfile.ZipFile(jar_path) as zf:
        members = [
            name
            for name in zf.namelist()
            if name == "pack.mcmeta"
            or name == "pack.png"
            or name == ".mcassetsroot"
            or name.startswith("assets/")
        ]

        for name in members:
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


def download_vanilla_assets(
    version: str,
    dest_dir: Path,
    jar_path: Optional[Path],
    minecraft_dir: Path,
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
        client_download = version_json.get("downloads", {}).get("client")
        if client_download is None:
            raise ValueError(f"Version {version} does not expose a client download.")

        expected_sha1 = client_download.get("sha1")
        with tempfile.TemporaryDirectory(prefix="minecraft-assets-") as temp_dir:
            temp_jar_path = Path(temp_dir) / f"{version}.jar"
            _download_file(client_download["url"], temp_jar_path)
            if expected_sha1:
                actual_sha1 = _sha1_file(temp_jar_path)
                if actual_sha1.lower() != expected_sha1.lower():
                    raise ValueError(
                        f"SHA-1 mismatch for downloaded jar: expected {expected_sha1}, got {actual_sha1}"
                    )
            _safe_extract_assets(temp_jar_path, dest_dir)
            return

    _safe_extract_assets(jar_path, dest_dir)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Download and extract vanilla Minecraft assets from Mojang's official "
            "version manifest and client jar."
        )
    )
    parser.add_argument(
        "version",
        help="Minecraft version to extract, for example 1.21.11",
    )
    parser.add_argument(
        "--dest",
        type=Path,
        default=None,
        help="Destination directory. Defaults to vanilla/<version>.",
    )
    parser.add_argument(
        "--jar-path",
        type=Path,
        default=None,
        help="Use an existing client jar instead of downloading or searching .minecraft.",
    )
    parser.add_argument(
        "--minecraft-dir",
        type=Path,
        default=_default_minecraft_dir(),
        help="Minecraft directory to search for an existing local jar.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite the destination directory if it already exists.",
    )

    args = parser.parse_args()
    destination = args.dest if args.dest is not None else Path("vanilla") / args.version
    download_vanilla_assets(
        version=args.version,
        dest_dir=destination,
        jar_path=args.jar_path,
        minecraft_dir=args.minecraft_dir,
        force=args.force,
    )
    print(f"Extracted vanilla assets for {args.version} to {destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
