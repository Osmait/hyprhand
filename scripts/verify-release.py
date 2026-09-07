#!/usr/bin/env python3
"""Verify a deskctl archive and checksum without extracting or executing it."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import tarfile


def verify(archive_path):
    checksum = Path(str(archive_path) + ".sha256").read_text(encoding="utf-8")
    digest = hashlib.sha256()
    with archive_path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    if checksum != f"{digest.hexdigest()}  {archive_path.name}\n":
        raise ValueError("archive checksum mismatch")
    root = archive_path.name.removesuffix(".tar.gz")
    with tarfile.open(archive_path, "r:gz") as archive:
        files = {}
        seen = set()
        for member in archive.getmembers():
            path = PurePosixPath(member.name)
            if (path.is_absolute() or ".." in path.parts or not path.parts
                    or path.parts[0] != root or member.name in seen
                    or not (member.isfile() or member.isdir())):
                raise ValueError("unsafe or duplicate archive member")
            seen.add(member.name)
            if member.uid or member.gid or member.uname or member.gname:
                raise ValueError("archive contains local ownership metadata")
            relative = path.relative_to(root).as_posix()
            expected_mode = 0o755 if member.isdir() or relative == "bin/deskctl" else 0o644
            if member.mode != expected_mode:
                raise ValueError("unexpected archive permissions")
            if member.isfile():
                files[relative] = member
        if "SHA256SUMS" not in files:
            raise ValueError("payload checksum manifest is missing")
        expected = {}
        for line in archive.extractfile(files["SHA256SUMS"]).read().decode("utf-8").splitlines():
            match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
            if not match or match[2] in expected:
                raise ValueError("malformed or duplicate payload checksum")
            expected[match[2]] = match[1]
        if set(expected) != set(files) - {"SHA256SUMS"}:
            raise ValueError("payload checksum inventory mismatch")
        for name, value in expected.items():
            digest = hashlib.sha256()
            with archive.extractfile(files[name]) as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
            if digest.hexdigest() != value:
                raise ValueError(f"payload checksum mismatch: {name}")
        metadata = json.load(archive.extractfile(files["metadata.json"]))
        dependencies = json.load(archive.extractfile(files["dependencies.json"]))
        if metadata["validation"] != {
            "unit_tests": "passed", "fake_compositor_integration": "passed",
            "keyboard_unit": "passed", "keyboard_protocol": "passed",
            "session_lifecycle": "passed",
            "reliability_contract": "passed",
            "live_desktop": "not_run", "blender": "not_run",
        }:
            raise ValueError("unexpected validation claims")
        if metadata["optional_compositor_bridges_included"] or dependencies["bundled_system_libraries"]:
            raise ValueError("unexpected bundled libraries")
        if not dependencies["observed_build"]["direct_needed_sonames"]:
            raise ValueError("missing dynamic dependencies")
    return len(expected)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()
    try:
        count = verify(args.archive)
    except (OSError, ValueError, KeyError, tarfile.TarError) as exc:
        parser.exit(1, f"Verification failed: {exc}\n")
    print(f"Verified archive and {count} payload checksums; nothing extracted or executed.")


if __name__ == "__main__":
    main()
