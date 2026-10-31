# Hyprhand style

Hyprhand follows [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md),
adapted to a short-lived command-line tool. The goal is code that a reader can
verify line by line: short lines, full names, types that state intent, and
assertions that document what must be true.

`python3 scripts/check_style.py` enforces the mechanical rules. `zig build check`
runs it together with `zig fmt --check`.

## Layout

- Lines are at most **100 columns**, without exception. Break long calls and
  struct literals with a trailing comma so `zig fmt` puts one item per line.
- Functions are at most **70 lines**. Split by responsibility, not at an
  arbitrary line: keep control flow (`if`, `switch`) in the parent and move
  straight-line work into helpers.
- Use 4 spaces of indentation (`zig fmt`).
- Use braces on an `if` unless the whole statement fits on one line.
- Separate groups of related statements with a blank line: validate, then act,
  then report.

## Control flow

- Prefer one condition per guard clause. Instead of
  `if (a or b or c) return error.X;` write three lines, each testing one fact.
- State conditions positively where possible; avoid double negation.
- Split compound boolean expressions into named `const` values when the name
  explains the intent (`const outside_target = ...;`).
- No recursion.

## Naming

- Functions, variables and files use `snake_case`; types use `PascalCase`.
- Do not abbreviate: `runtime`, `arguments`, `allocator`, `character`, `buffer`.
  Conventional exceptions: `c` (the translated C module), `fd`, `x`/`y`/`dx`/`dy`
  for coordinates, `i`/`j` for loop indexes over primitive integers, `id`.
- Put units and qualifiers last, ordered by significance: `timeout_ms`,
  `columns_max`, `frame_age_ms_max`.
- A helper called from a single function is prefixed with that function's name
  (`create_compositor_start` belongs to `create`).
- Don't give one name two meanings. `runtime` is the `*Runtime`;
  `runtime_directory` is `$XDG_RUNTIME_DIR`.
- Persisted or emitted names (session metadata, JSON output, CLI options) are
  part of the interface. Renaming them is a behavior change, not a style change.

## Types and invariants

- Use an `enum` for a closed set of values, never a string compared with `eq`.
- Make invalid states unrepresentable: parse arguments into the struct a command
  needs instead of carrying optional fields and unwrapping them with `.?`.
- Assert programmer invariants with `std.debug.assert` (preconditions,
  postconditions, relationships between values). Operating errors (bad input,
  missing windows, compositor failures) return errors instead.
- Put a limit on everything: sizes, counts, timeouts, retries.

## Comments

- Explain **why**, not what. Code shows what happens; comments record the reason,
  the protocol detail or the failure mode that motivated it.
- Comments are sentences: a capital letter and a full stop.
- Tests start with a comment or name that says what they prove.

## What we do not adopt

- Static allocation at startup. Each command is a short-lived process and uses
  arena allocators scoped to the command or to a polling iteration.
