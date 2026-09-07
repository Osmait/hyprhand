# Local release packaging

Packaging is opt-in. It creates a native Linux x86_64 archive, runs unit,
keyboard unit/protocol, fake-compositor, session-lifecycle and offline reliability
contract tests, and checks that the requested version matches the built
binary. It never runs Blender, live desktop tests, or commands that inject host
input. It does not create a release, tag, commit or upload anything itself.

From the checkout, with the [build dependencies](../docs/dependencies.md):

```sh
python3 scripts/package-release.py --version 0.4.0 --output /tmp/deskctl-release-0.4.0
```

Use the actual source version and a new output directory. Existing output paths
are rejected, including symlinks. A failed build can leave an empty output
directory; choose a fresh path for the next attempt. Builds use a temporary
install prefix and cache, so stale files in `zig-out` cannot enter the package.
The Zig global cache may still be reused. Dirty trees are allowed for local
review and recorded as `source_dirty: true`; the commit alone then does not
identify all packaged changes. No source snapshots or Git remotes are recorded.

Python 3.11+ is required for the lifecycle fixture's process-group handling.
Both CI runners select Python 3.12 explicitly, including Ubuntu 22.04, whose
system Python alone is too old for that fixture. The non-desktop entry points
are `tests/integration.py`, `tests/keyboard_unit.py`, `tests/keyboard_protocol.py`,
`tests/session_lifecycle.py` and `tests/fixtures/test_reliability_contract.py`.
The keyboard protocol suite uses private fake
Wayland/Hyprland sockets and the already-required libxkbcommon; it needs no live
compositor or additional desktop packages.
The reliability contract suite imports `tests/live_reliability.py` and
`tests/fixtures/reliability.py` to check safety gates and receiver evidence with
synthetic records and mocked operations. It does not invoke deskctl, import GTK
or open a GUI. CI also checks these modules' syntax; live tests remain opt-in.

The archive name contains the application version, OS, architecture, build
distribution/version and build glibc version. Its contents are explicitly
selected: the stripped ReleaseSafe executable, Bash/Fish completions, the
deskctl skill, the main usage guide and supporting documentation, and these manifests:

- `metadata.json`: version, source commit/dirty state, Zig version, CPU baseline,
  build platform and completed non-live checks. Live tests are `not_run`.
- `dependencies.json`: required build/runtime components plus observed
  pkg-config versions, ELF interpreter, direct library SONAMEs and glibc symbol
  requirements. This is a dependency manifest, not a complete transitive SBOM.
- `SHA256SUMS`: every payload file other than the checksum list itself.

Start with [README.md](../README.md) at the archive root. `PLAN.md`, `docs/` and `packaging/`
keep their checkout-relative layout so local documentation links work after
extraction. This includes the [0.4.0 reliability report](../docs/reliability-040.md),
[experimental hardening report](../docs/experimental-hardening.md) and existing compatibility, dependency and
probe reports. All listed documents are required; packaging fails before building
if one is missing. The usage guide also contains source-build and test commands;
those require a source checkout, as sources and test runners are not bundled.

A separate `.tar.gz.sha256` verifies the archive. From the output directory,
verify before extracting; then verify the files inside the extracted directory:

```sh
sha256sum --check deskctl-VERSION-PLATFORM.tar.gz.sha256
tar -xzf deskctl-VERSION-PLATFORM.tar.gz
cd deskctl-VERSION-PLATFORM
sha256sum --check SHA256SUMS
```

Replace `VERSION-PLATFORM` with the exact filename produced. Checksums detect
corruption; they are not signatures or proof of provenance. Archive ownership,
ordering and timestamps are normalized. `SOURCE_DATE_EPOCH` can set the timestamp
(default: source commit time); reproducible bytes across different toolchains,
source paths or hosts are not promised.

From the checkout, `python3 scripts/verify-release.py /path/to/ARCHIVE.tar.gz`
checks the outer checksum, every payload checksum and normalized archive
metadata without extracting or executing any files.

This is **not a universal portable or static binary**. Install compatible system
libraries, the matching loader, Hyprland and feature-specific helper programs.
The recorded build glibc is not the same thing as the executable's symbol floor;
neither alone establishes compatibility of all transitive libraries. No compositor,
GPU drivers or optional experimental `.so` bridges are bundled. Installation is
manual; packaging never writes to system prefixes or desktop configuration.

The optional GTK4 `deskctl-pip` viewer is also excluded. Build it explicitly from
the matching source checkout with `zig build pip` and install it beside `deskctl`.
The CLI archive includes [preview usage and limits](../docs/preview.md), but does
not acquire a GTK runtime dependency. CI checks its build on Ubuntu 24.04 and
runs `tests/preview.py` without a GUI on both matrix entries.

`.github/workflows/release-package.yml` offers a manual `workflow_dispatch` with
an explicit `package` checkbox (false by default). It builds on Ubuntu 22.04 and
24.04 x86_64 and uploads only the two deliverable files per platform as Actions
artifacts, with seven-day retention. The workflow has read-only repository
permissions and no release/tag publishing steps. Actions artifacts follow the
repository's access controls; the workflow does not change private visibility
or any GitHub settings. Availability of private-repository hosted runners depends
on the account's Actions configuration and quota. No remote run is implied by
the presence of these workflows.

No project license has been selected. Creating a package does not grant project
redistribution rights; a license decision remains with the repository owner.
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) preserves the original Wayland
protocol permissions independently of that decision.

Before publication, follow the [readiness report](../docs/open-source-readiness.md).
`python3 scripts/check_docs.py` validates local documentation links and the package
payload. Example/fixture guides and the skill instructions are included so those
links work; source code, test runners and editable Blender scenes remain excluded.
The four README images, recorded demo video, poster, subtitles and normalized
provenance are included so the illustrated guide also works after extraction.
Raw recordings and unredacted command logs remain excluded.
