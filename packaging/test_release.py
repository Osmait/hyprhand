"""Packaging regressions and Blender path preflight; never import bpy or run Blender."""
import argparse
import ast
import importlib.util
import json
import os
from pathlib import Path
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release = load_script("package-release")
verifier = load_script("verify-release")


class Packaging(unittest.TestCase):
    def test_reject_version_paths_and_shell_fragments(self):
        for value in ("../0.3.0", "v0.3.0", "0.3.0\n", "$(id)", "0.3.0;id", "0.3.0/other"):
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                release.checked_version(value)
        self.assertEqual(release.checked_version("0.3.0-rc.1"), "0.3.0-rc.1")

    def test_existing_output_rejected_before_build(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(release, "run") as run:
            with self.assertRaisesRegex(ValueError, "already exist"):
                release.package("0.3.0", Path(temp))
            run.assert_not_called()

    def test_archive_integrity_and_normalized_headers(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            payload = root / "deskctl-0.3.0-test"
            (payload / "bin").mkdir(parents=True)
            (payload / "bin/deskctl").write_bytes(b"fixture, never executed")
            release.write_json(payload / "metadata.json", {
                "validation": {"unit_tests": "passed", "fake_compositor_integration": "passed",
                               "keyboard_unit": "passed", "keyboard_protocol": "passed",
                               "session_lifecycle": "passed",
                               "reliability_contract": "passed",
                               "live_desktop": "not_run", "blender": "not_run"},
                "optional_compositor_bridges_included": False,
            })
            release.write_json(payload / "dependencies.json", {
                "bundled_system_libraries": False,
                "observed_build": {"direct_needed_sonames": ["libc.so.6"]},
            })
            paths = sorted(path for path in payload.rglob("*") if path.is_file())
            (payload / "SHA256SUMS").write_text("".join(
                f"{release.sha256(path)}  {path.relative_to(payload)}\n" for path in paths))
            archive = root / f"{payload.name}.tar.gz"
            release.make_archive(payload, archive, 1234)
            checksum = Path(str(archive) + ".sha256")
            checksum.write_text(f"{release.sha256(archive)}  {archive.name}\n")
            self.assertEqual(verifier.verify(archive), 3)
            with tarfile.open(archive) as contents:
                self.assertTrue(all(member.mtime == 1234 for member in contents.getmembers()))
            # Rebuilding normalizes filesystem times and incidental permissions.
            (payload / "bin/deskctl").chmod(0o700)
            second = root / "second.tar.gz"
            release.make_archive(payload, second, 1234)
            self.assertEqual(archive.read_bytes(), second.read_bytes())
            # A valid outer checksum cannot hide altered payload contents.
            (payload / "bin/deskctl").write_bytes(b"changed")
            changed = root / "changed"
            changed.mkdir()
            tampered = changed / archive.name
            release.make_archive(payload, tampered, 1234)
            Path(str(tampered) + ".sha256").write_text(f"{release.sha256(tampered)}  {tampered.name}\n")
            with self.assertRaisesRegex(ValueError, "payload checksum mismatch"):
                verifier.verify(tampered)
            checksum.write_text("0" * 64 + f"  {archive.name}\n")
            with self.assertRaisesRegex(ValueError, "archive checksum mismatch"):
                verifier.verify(archive)

    def test_symlink_payload_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            payload = root / "payload"
            payload.mkdir()
            (payload / "link").symlink_to("/etc/passwd")
            with self.assertRaisesRegex(ValueError, "regular files"):
                release.make_archive(payload, root / "output.tar.gz", 0)

    def test_dependency_manifest_and_pin(self):
        manifest = json.loads((ROOT / "packaging/dependencies.json").read_text())
        self.assertEqual(manifest["build"]["zig"], (ROOT / ".zigversion").read_text().strip())
        self.assertFalse(manifest["bundled_system_libraries"])


class BlenderPaths(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        tree = ast.parse((ROOT / "examples/blender/style_room.py").read_text())
        # Execute ONLY the path-selection preflight against plain Python stubs.
        # Stop before random.seed / scene access / any scene mutation or bpy call.
        start = next(i for i, node in enumerate(tree.body)
                     if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "output_dir"
                                                            for t in node.targets))
        end = next(i for i, node in enumerate(tree.body)
                   if isinstance(node, ast.Expr) and isinstance(node.value, ast.Call)
                   and isinstance(node.value.func, ast.Attribute) and node.value.func.attr == "seed")
        cls.preflight = compile(ast.Module(body=tree.body[start:end], type_ignores=[]), "path-preflight", "exec")

    def resolve(self, filepath, env):
        namespace = {"Path": Path, "os": SimpleNamespace(environ=env),
                     "bpy": SimpleNamespace(data=SimpleNamespace(filepath=filepath))}
        exec(self.preflight, namespace)
        return namespace["ROOT"]

    def test_open_blend_and_explicit_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.assertEqual(self.resolve(str(root / "original.blend"), {}), root.resolve())
            self.assertEqual(self.resolve("", {"DESKCTL_BLENDER_OUTPUT_DIR": temp}), root.resolve())
            self.assertEqual(self.resolve("/different/original.blend", {"DESKCTL_BLENDER_OUTPUT_DIR": temp}), root.resolve())

    def test_unsaved_relative_missing_and_overwrite_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "Save the room"):
            self.resolve("", {})
        with self.assertRaisesRegex(ValueError, "absolute"):
            self.resolve("", {"DESKCTL_BLENDER_OUTPUT_DIR": "relative"})
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(ValueError, "already exist"):
                self.resolve("", {"DESKCTL_BLENDER_OUTPUT_DIR": str(Path(temp) / "missing")})
            with self.assertRaisesRegex(RuntimeError, "preserve"):
                self.resolve(str(Path(temp) / "habitacion-realista.blend"), {})


if __name__ == "__main__":
    unittest.main()
