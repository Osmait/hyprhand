#!/usr/bin/env python3
"""Explicit local packaging only. Never publishes, creates tags, or uses desktop input."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[1]
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?")
# Explicit payload: never recursively collect the checkout, profiles, examples,
# caches, logs, environment files, or optional compositor libraries.
INSTALLED_FILES = (
    "bin/deskctl",
    "share/bash-completion/completions/deskctl",
    "share/fish/vendor_completions.d/deskctl.fish",
    "share/deskctl/skills/deskctl/SKILL.md",
    "share/deskctl/skills/deskctl/agents/openai.yaml",
)
# Keep the source-relative documentation tree at the archive root so README
# usage links and links between docs work without rewriting user-authored text.
DOCUMENTS = {relative: relative for relative in (
    "README.md", "PLAN.md", "packaging/README.md", "packaging/dependencies.json",
    "docs/dependencies.md", "docs/compatibility.md",
    "docs/experimental-bridges.md", "docs/background-probe.md",
    "docs/cursor-outline-probe.md", "docs/reliability-040.md",
    "docs/experimental-hardening.md", "docs/preview.md",
)}


def run(*args, env=None):
    return subprocess.check_output(args, cwd=ROOT, env=env, text=True).strip()


def checked_version(value):
    if not VERSION.fullmatch(value):
        raise argparse.ArgumentTypeError("use a version like 0.4.0 or 0.4.0-rc.1 (no v prefix)")
    return value


def safe_component(value):
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]*", value):
        raise ValueError("invalid platform identifier")
    return value


def elf_dependencies(binary):
    # Inspect ELF data without ldd (which can execute a binary's interpreter).
    env = dict(os.environ, LC_ALL="C")
    dynamic = run("readelf", "--wide", "--dynamic", str(binary), env=env)
    headers = run("readelf", "--wide", "--program-headers", str(binary), env=env)
    versions = run("readelf", "--wide", "--version-info", str(binary), env=env)
    needed = sorted(set(re.findall(r"\(NEEDED\).*?\[([^\]]+)\]", dynamic)))
    loader = re.search(r"Requesting program interpreter: ([^\]]+)\]", headers)
    if not needed or loader is None:
        raise ValueError("expected a dynamically linked Linux executable")
    if re.search(r"\((?:RPATH|RUNPATH)\)", dynamic):
        raise ValueError("release binary must not embed a library search path")
    glibc = sorted(set(re.findall(r"\bGLIBC_[0-9.]+", versions)),
                   key=lambda item: tuple(map(int, item[6:].split("."))))
    if not glibc:
        raise ValueError("expected versioned glibc requirements")
    return {
        "elf_interpreter": loader.group(1),
        "direct_needed_sonames": needed,
        "glibc_symbol_versions": glibc,
        "highest_required_glibc_symbol_version": glibc[-1],
        "scope": "Direct ELF dependencies only; transitive libraries and helper programs must also be installed. The glibc symbol floor is not a complete compatibility guarantee.",
    }


def copy_regular(source, destination, executable=False):
    if source.is_symlink() or not source.is_file():
        raise ValueError(f"expected regular payload file: {source.name}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    destination.chmod(0o755 if executable else 0o644)


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def make_archive(payload, target, epoch):
    # Stable file order, times and ownership; no local username or build paths
    # in tar/gzip headers. This alone does not promise reproducible Zig builds.
    with target.open("xb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=epoch) as zipped:
            with tarfile.open(fileobj=zipped, mode="w", format=tarfile.PAX_FORMAT) as archive:
                for path in [payload, *sorted(payload.rglob("*"))]:
                    if path.is_symlink() or not (path.is_dir() or path.is_file()):
                        raise ValueError("archive payload must contain only regular files and directories")
                    info = archive.gettarinfo(str(path), arcname=str(path.relative_to(payload.parent)))
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    info.mtime = epoch
                    info.mode = 0o755 if path.is_dir() or path == payload / "bin/deskctl" else 0o644
                    info.pax_headers = {}
                    if path.is_file():
                        with path.open("rb") as stream:
                            archive.addfile(info, stream)
                    else:
                        archive.addfile(info)


def package(version, output):
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise ValueError("packaging currently supports native Linux x86_64 only")
    if output.exists() or output.is_symlink():
        raise ValueError("output directory must not already exist; choose a fresh path")
    if sys.version_info < (3, 11):
        raise ValueError("packaging requires Python 3.11+ for the session lifecycle fixtures")
    for relative in DOCUMENTS:
        source = ROOT / relative
        if source.is_symlink() or not source.is_file():
            raise ValueError(f"required package document is missing or not a regular file: {relative}")
    requirements = json.loads((ROOT / "packaging/dependencies.json").read_text())
    zig_version = run("zig", "version")
    if zig_version != requirements["build"]["zig"] or zig_version != (ROOT / ".zigversion").read_text().strip():
        raise ValueError("packaging requires the pinned Zig 0.16.0 toolchain")
    for command in ("readelf", "strip", "pkg-config", "wayland-scanner", "git"):
        if shutil.which(command) is None:
            raise ValueError(f"required packaging command is missing: {command}")
    modules = {name: run("pkg-config", "--modversion", name)
               for name in requirements["build"]["pkg_config_modules"]}
    libc_name, libc_version = platform.libc_ver()
    if libc_name != "glibc" or not libc_version:
        raise ValueError("packaging currently requires a glibc build host")
    distro = platform.freedesktop_os_release()
    distro_id = safe_component(distro["ID"])
    distro_version = safe_component(distro.get("VERSION_ID", "rolling"))
    label = f"linux-x86_64-{distro_id}-{distro_version}-glibc{safe_component(libc_version)}"
    name = f"deskctl-{version}-{label}"
    commit = run("git", "rev-parse", "HEAD")
    dirty = bool(run("git", "status", "--porcelain", "--untracked-files=normal"))
    epoch = int(os.environ.get("SOURCE_DATE_EPOCH", run("git", "show", "-s", "--format=%ct", "HEAD")))
    if not 0 <= epoch <= 0xFFFFFFFF:
        raise ValueError("SOURCE_DATE_EPOCH must fit a gzip timestamp (0..4294967295)")
    # Reserve a new output directory; never overwrite any existing artifacts.
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix="deskctl-package-") as workspace:
        work = Path(workspace)
        prefix = work / "install"
        flags = ["-Doptimize=ReleaseSafe", "-Dcpu=baseline", "--summary", "all",
                 "--prefix", str(prefix), "--cache-dir", str(work / "cache")]
        subprocess.run(["zig", "build", "test", *flags], cwd=ROOT, check=True)
        subprocess.run(["zig", "build", *flags], cwd=ROOT, check=True)
        binary = prefix / "bin/deskctl"
        subprocess.run(["strip", "--strip-all", str(binary)], check=True)
        actual_version = run(str(binary), "--version")
        if actual_version != f"deskctl {version}":
            raise ValueError("requested version does not match the built binary's --version")
        for suite in ("tests/integration.py", "tests/keyboard_unit.py",
                      "tests/keyboard_protocol.py", "tests/session_lifecycle.py",
                      "tests/fixtures/test_reliability_contract.py"):
            subprocess.run([sys.executable, "-B", suite], cwd=ROOT, check=True,
                           env=dict(os.environ, DESKCTL_TEST_BIN=str(binary)))
        observed = elf_dependencies(binary)
        payload = work / name
        payload.mkdir()
        for relative in INSTALLED_FILES:
            copy_regular(prefix / relative, payload / relative, executable=relative == "bin/deskctl")
        for source, destination in DOCUMENTS.items():
            copy_regular(ROOT / source, payload / destination)
        requirements["observed_build"] = {"pkg_config_versions": modules, **observed}
        write_json(payload / "dependencies.json", requirements)
        write_json(payload / "metadata.json", {
            "schema_version": 1,
            "name": "deskctl", "version": version,
            "platform": {"os": "linux", "architecture": "x86_64", "cpu": "baseline",
                         "distribution": distro_id, "distribution_version": distro_version,
                         "build_libc": libc_name, "build_libc_version": libc_version},
            "build": {"zig_version": zig_version, "optimize": "ReleaseSafe", "stripped": True,
                      "source_commit": commit, "source_dirty": dirty, "source_date_epoch": epoch},
            "validation": {"unit_tests": "passed", "fake_compositor_integration": "passed",
                           "keyboard_unit": "passed", "keyboard_protocol": "passed",
                           "session_lifecycle": "passed",
                           "reliability_contract": "passed",
                           "live_desktop": "not_run", "blender": "not_run"},
            "distribution": "system-library-dependent; not universal portable or static",
            "license": "unspecified; packaging does not grant redistribution rights",
            "optional_compositor_bridges_included": False,
        })
        files = sorted(path for path in payload.rglob("*") if path.is_file())
        (payload / "SHA256SUMS").write_text("".join(
            f"{sha256(path)}  {path.relative_to(payload).as_posix()}\n" for path in files), encoding="utf-8")
        # Stage both deliverables privately and expose them only after success.
        with tempfile.TemporaryDirectory(prefix=".staging-", dir=output) as staging:
            archive = Path(staging) / f"{name}.tar.gz"
            make_archive(payload, archive, epoch)
            checksum = Path(staging) / f"{archive.name}.sha256"
            checksum.write_text(f"{sha256(archive)}  {archive.name}\n", encoding="utf-8")
            archive.rename(output / archive.name)
            checksum.rename(output / checksum.name)
    print(f"Created {output / (name + '.tar.gz')}")
    print("Local package only. No release, tag, upload, or live desktop test performed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, type=checked_version)
    parser.add_argument("--output", required=True, type=Path, help="new output directory (must not exist)")
    args = parser.parse_args()
    try:
        package(args.version, args.output.absolute())
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"Packaging failed: {exc}\n")


if __name__ == "__main__":
    main()
