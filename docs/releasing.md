# Release checklist

Use this checklist when preparing a public source release or binary distribution.
The [packaging guide](../packaging/README.md) describes archive contents and commands;
the [testing guide](testing.md) describes offline and optional live verification.

## Before the first public release

- Have the repository owner select a project license. Include it in the source,
  installed documentation and package payload, and update the README and package
  metadata. **A project license has not yet been selected.** Preserve the separate
  [third-party notices](../THIRD_PARTY_NOTICES.md).
- Review tracked files, example metadata and Git history for private information.
  The September 2026 preparation review found personal paths in two historical
  blobs; cleaning the current tree did not remove them from history. Any history
  rewrite or visibility change requires a deliberate owner decision.
- Review repository description/topics, branch protection, issue settings and
  private vulnerability reporting. Keep the [security policy](../SECURITY.md)
  consistent with the reporting channels actually enabled.

## For each release

1. Check the intended version and update affected CLI, installation, compatibility
   and example documentation. Keep public documentation in English.
2. Run `zig build check -Doptimize=ReleaseSafe` and
   `python3 scripts/check_docs.py`. If the optional viewer changed, run its build,
   ABI and private GTK checks from the testing guide. Record any live verification
   separately with its exact environment and limitations.
3. Confirm CI passes for the exact commit. Earlier successful runs do not validate
   a later change. Check both configured Ubuntu build targets.
4. Build packages using the packaging guide or the manual packaging workflow.
   Verify each intended platform archive with `scripts/verify-release.py`, and
   inspect its version, dependency metadata, documentation and checksums.
5. Review the final artifacts and release notes before creating a tag or GitHub
   Release. State supported environments and known limitations accurately.

The manual packaging workflow uploads Actions artifacts only. It does not create
tags, publish GitHub Releases or change repository visibility. Keep raw recordings,
profiles and unredacted logs out of releases; published demonstration provenance
belongs with its [example guide](../examples/spreadsheet/README.md).
