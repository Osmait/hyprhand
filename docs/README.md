# Documentation

Start with the [project README](../README.md) for the purpose, installation, and
first session. Commands and documentation refer to source version **0.4.0**.

## User guides

| Guide | Contents |
| --- | --- |
| [Rename and upgrade notes](renaming.md) | Moving from deskctl to Hyprhand, installation paths and existing sessions |
| [Dependencies](dependencies.md) | Build packages, runtime helpers, optional components, installation and removal |
| [CLI reference](cli.md) | Commands, options, frame coordinates, JSON contract, input and cancellation |
| [Managed sessions](sessions.md) | Host versus child sessions, environment routing, profiles and lifecycle |
| [Picture-in-Picture](preview.md) | Build, controls, transport, freshness, performance and limitations |
| [Troubleshooting](troubleshooting.md) | Common error codes, diagnosis and recovery |
| [Compatibility](compatibility.md) | Tested environments and unverified configurations |
| [Experimental bridges](experimental-bridges.md) | Headless format bridge and continuous cursor outline |
| [Spreadsheet agent demo](../examples/spreadsheet/README.md) | Actual prompt submission, Calc formulas, formatting and a chart |
| [Recorded agent demo](../examples/video/README.md) | Real prompt-to-desktop video, transcript and editing provenance |
| [GTK note demo](../examples/gtk/README.md) | Reproduce typing, a guarded click, and visible verification |
| [README images](images/README.md) | Screenshot provenance and reproduction details |
| [Blender example](../examples/blender/README.md) | Scene assets, styling script and output behavior |

## Development and distribution

- [Contributing](../CONTRIBUTING.md): development workflow, conventions and reviews.
- [Architecture](architecture.md): source map, runtime checks and resource ownership.
- [Testing](testing.md): offline, private GTK, and explicitly enabled live suites.
- [Packaging](../packaging/README.md): local archives, manifests and verification.
- [Security](../SECURITY.md): trust boundaries, data handling and reporting.
- [Third-party notices](../THIRD_PARTY_NOTICES.md): vendored protocol attribution.
- [Product](../PRODUCT.md), [design](../DESIGN.md), and [delivery ledger](../PLAN.md).

## Historical evidence

These reports describe particular runs, versions, and machines. Their test counts
and timings are historical; they do not establish current CI status or universal
compatibility.

- [Initial September audit](audit-2026-09.md)
- [Audit follow-up](audit-followup-2026-09.md)
- [Performance follow-up](performance-2026-09.md)
- [0.4.0 reliability report](reliability-040.md)
- [Hidden-workspace probe](background-probe.md)
- [Cursor capture probe](cursor-outline-probe.md)
- [Experimental bridge hardening](experimental-hardening.md)
