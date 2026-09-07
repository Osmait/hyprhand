#!/usr/bin/env python3
"""Validate repository Markdown file links and the explicit archive's doc links.

Offline only. This checks file targets, not remote URLs or heading anchors.
Inline links are supported; code fences and inline code are excluded.
"""
import importlib.util
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
LINK = re.compile(r"!?\[[^\]\n]*\]\(\s*(?:<([^>]+)>|([^\s)]+))(?:\s+[\"'][^\n]*?[\"'])?\s*\)")


def local_links(text):
    fence = None
    for line in text.splitlines():
        marker = re.match(r"^\s{0,3}(`{3,}|~{3,})", line)
        if marker:
            value = marker.group(1)
            if fence is None:
                fence = value
            elif value[0] == fence[0] and len(value) >= len(fence):
                fence = None
            continue
        if fence:
            continue
        line = re.sub(r"(`+).*?\1", "", line)
        for match in LINK.finditer(line):
            target = match.group(1) or match.group(2)
            parsed = urlsplit(target)
            if not parsed.scheme and not parsed.netloc and parsed.path:
                yield unquote(parsed.path)


def package_documents():
    spec = importlib.util.spec_from_file_location("deskctl_package", ROOT / "scripts/package-release.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.DOCUMENTS


def validate_package_links(documents, root=ROOT):
    errors = []
    payload = {(root / destination).resolve() for destination in documents.values()}
    for source, destination in documents.items():
        path = root / source
        if path.is_symlink() or not path.is_file():
            errors.append(f"Package document is missing or not a regular file: {source}")
            continue
        if path.suffix != '.md':
            continue
        for target in local_links(path.read_text(encoding='utf-8')):
            resolved = ((root / destination).parent / target).resolve()
            if resolved not in payload:
                errors.append(f"Package link has no payload target: {destination} -> {target}")
    return errors


def main():
    listed = subprocess.check_output(
        ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT
    ).decode().split('\0')
    paths = sorted({ROOT / name for name in listed if name.endswith('.md')})
    errors = []
    count = 0
    for path in paths:
        if not path.is_file():  # Renamed/deleted tracked files can still be in the index.
            continue
        count += 1
        for target in local_links(path.read_text(encoding='utf-8')):
            resolved = (path.parent / target).resolve()
            if not resolved.is_relative_to(ROOT) or not resolved.exists():
                errors.append(f"Broken local link: {path.relative_to(ROOT)} -> {target}")
    errors.extend(validate_package_links(package_documents()))
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        return 1
    print(f"Documentation checks passed: {count} Markdown files and package link targets")
    return 0


if __name__ == '__main__':
    sys.exit(main())
