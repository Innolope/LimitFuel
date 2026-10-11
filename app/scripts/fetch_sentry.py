#!/usr/bin/env python3
"""Fetch the pinned official static macOS SDK; print its framework search directory."""
import argparse
import fcntl
import hashlib
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import time
import zipfile
import zlib

VERSION = "9.30.1"
SHA256 = "bf6bc2308b9f1d11cc0d5ad5a324dbe300afa37c8391809ecb6dd3758fa728e2"
LICENSE_SHA256 = "1784335a04bbe8014b9bf0f6a373f7b3804855792545702199dbdd6e2c5b6ad1"
URL = f"https://github.com/getsentry/sentry-cocoa/releases/download/{VERSION}/Sentry.xcframework.zip"
LICENSE_URL = f"https://raw.githubusercontent.com/getsentry/sentry-cocoa/{VERSION}/LICENSE.md"
SLICE = "Sentry.xcframework/macos-arm64_arm64e_x86_64/"
ROOT = Path(__file__).resolve().parents[1] / ".dependencies"


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def fetch(path, url, expected, max_size, offline):
    if path.exists() and digest(path) == expected:
        return
    if offline:
        raise RuntimeError(f"Missing or invalid pinned Sentry cache: {path.name}; run fetch_sentry.py once online")
    temporary = path.with_suffix(path.suffix + ".download")
    try:
        subprocess.run(["/usr/bin/curl", "--fail", "--location", "--silent", "--show-error",
                        "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "10",
                        "--max-time", "120", "--max-filesize", str(max_size),
                        "--output", str(temporary), url], check=True, timeout=130)
        if temporary.stat().st_size > max_size or digest(temporary) != expected:
            raise RuntimeError("Sentry dependency checksum mismatch")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def selected(info):
    return info.filename.startswith(SLICE) or info.filename == "Sentry.xcframework/Info.plist"


def cache_valid(destination, members):
    for item in members:
        file = destination / item.filename
        if item.is_dir():
            if not file.is_dir():
                return False
        elif stat.S_ISLNK(item.external_attr >> 16):
            if not file.is_symlink() or zlib.crc32(os.readlink(file).encode()) != item.CRC:
                return False
        elif not file.is_file() or file.stat().st_size != item.file_size or zlib.crc32(file.read_bytes()) != item.CRC:
            return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--offline", action="store_true", help="Verify all cached files without downloads or repair")
    args = parser.parse_args()
    ROOT.mkdir(parents=True, exist_ok=True)
    with (ROOT / "sentry.lock").open("w") as lock:
        deadline = time.monotonic() + 140
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise RuntimeError("Timed out waiting for another Sentry dependency fetch")
                time.sleep(0.1)
        archive = ROOT / f"Sentry-{VERSION}.zip"
        fetch(archive, URL, SHA256, 100 * 1024 * 1024, args.offline)
        license_path = ROOT / f"Sentry-{VERSION}-LICENSE.md"
        fetch(license_path, LICENSE_URL, LICENSE_SHA256, 64 * 1024, args.offline)
        destination = ROOT / f"sentry-{VERSION}"
        with zipfile.ZipFile(archive) as source:
            members = [item for item in source.infolist() if selected(item)]
            if not members or sum(item.file_size for item in members) > 150 * 1024 * 1024:
                raise RuntimeError("Unexpected SDK archive layout or size")
            if not cache_valid(destination, members):
                if args.offline:
                    raise RuntimeError("Extracted SDK cache is missing or invalid; run fetch_sentry.py once online")
                with tempfile.TemporaryDirectory(prefix="sentry-extract-", dir=ROOT) as work:
                    work = Path(work)
                    subset = work / "macos.zip"
                    with zipfile.ZipFile(subset, "w", compression=zipfile.ZIP_DEFLATED) as output:
                        for item in members:
                            # Retain original Unix symlink attributes for ditto.
                            output.writestr(item, source.read(item))
                    extracted = work / "extracted"
                    subprocess.run(["/usr/bin/ditto", "-x", "-k", str(subset), str(extracted)],
                                   check=True, timeout=60)
                    if not cache_valid(extracted, members):
                        raise RuntimeError("Extracted SDK did not match the pinned archive")
                    if destination.exists():
                        shutil.rmtree(destination)
                    extracted.replace(destination)
        print(destination / SLICE)


if __name__ == "__main__":
    main()
