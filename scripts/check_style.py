#!/usr/bin/env python3
"""Enforce the mechanical parts of docs/STYLE.md on Zig sources.

Checks every Zig file under src/ and build/ plus build.zig:

- Lines are at most 100 columns.
- Function bodies are at most 70 lines, from `fn` to its closing brace.
- Function names use snake_case (types keep PascalCase).

Pass file paths to check only those files. Exit status 1 lists every violation.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
COLUMNS_MAX = 100
FUNCTION_LINES_MAX = 70
FUNCTION = re.compile(r"^\s*(?:pub\s+)?(?:inline\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")
CAMEL_CASE = re.compile(r"^[a-z][a-z0-9]*[A-Z]")


def sources(arguments):
    if arguments:
        return [Path(argument).resolve() for argument in arguments]
    paths = [ROOT / "build.zig"]
    paths += sorted((ROOT / "src").rglob("*.zig"))
    paths += sorted((ROOT / "build").rglob("*.zig"))
    return paths


def code_braces(line):
    """Counts braces outside string literals, character literals and comments."""
    line = re.sub(r'"(?:\\.|[^"\\])*"', '""', line)
    line = re.sub(r"'(?:\\.|[^'\\])'", "''", line)
    line = line.split("//", 1)[0]
    if line.lstrip().startswith("\\\\"):
        return 0
    return line.count("{") - line.count("}")


def check(path):
    relative = path.relative_to(ROOT)
    violations = []
    lines = path.read_text().split("\n")
    # The function being measured: its name, first line and brace depth.
    # Nested functions (struct methods) are measured by their outermost function.
    function_name = None
    function_start = 0
    function_body_opened = False
    depth = 0
    for number, line in enumerate(lines, start=1):
        if len(line) > COLUMNS_MAX:
            violations.append(f"{relative}:{number}: {len(line)} columns (max {COLUMNS_MAX})")

        match = FUNCTION.match(line)
        if match:
            name = match.group(1)
            if CAMEL_CASE.match(name):
                violations.append(f"{relative}:{number}: function {name} is not snake_case")
            is_declaration_only = line.rstrip().endswith(";") and "{" not in line
            if function_name is None and not is_declaration_only:
                function_name = name
                function_start = number
                function_body_opened = False
                depth = 0

        if function_name is None:
            continue
        depth += code_braces(line)
        if depth > 0:
            function_body_opened = True
        if function_body_opened and depth == 0:
            length = number - function_start + 1
            if length > FUNCTION_LINES_MAX:
                violations.append(
                    f"{relative}:{function_start}: function {function_name} has "
                    f"{length} lines (max {FUNCTION_LINES_MAX})"
                )
            function_name = None
    return violations


def main():
    violations = []
    for path in sources(sys.argv[1:]):
        violations += check(path)
    for violation in violations:
        print(violation)
    if violations:
        print(f"{len(violations)} style violations", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
