# Open-source preparation — 2026-09-07

This report tracks the local publication-preparation review. It is not a security
certification or a remote release record.

## Prepared in this checkout

- English README, command reference, session/dependency/testing/troubleshooting
  guides, documentation index, historical reports, viewer labels, fixtures and examples.
- Contribution/security guidance and GitHub issue/pull-request templates.
- Third-party protocol notices reproduced for binary distributions.
- Explicit packaging documentation payload and local-link validation.
- English Blender asset filenames, object/material labels, relative render paths,
  and removal of PNG export metadata while preserving compressed pixels.
- Ignore rules for local build, package and demonstration output.

## Publication decisions and checks

- **Project license:** still requires the repository owner's choice. Do not describe
  the project as licensed open source or distribute a public release until it is
  selected and included in source, installed documentation, and package metadata.
- **Remote CI:** run the workflows for the final commit. Historical passes do not
  validate these edits. Check the uploaded archive for the intended version/platform.
- **Git history:** the current-tree metadata cleanup does not erase older commits.
  The scan found two historical blobs with personal paths. Previous assets also
  retain their earlier labels. Review history
  before changing visibility; any history rewrite needs a deliberate owner decision.
- **Repository settings:** review visibility, description/topics, default branch,
  branch protection, issue/discussion settings and private vulnerability reporting
  in GitHub. None of these remote settings were changed by local preparation.
- **Release:** the manual packaging workflow creates Actions artifacts only.
  Tags, GitHub Releases and public publishing remain separate maintainer actions.

## Scope of inspection

The review covers tracked source, tests, build scripts, workflows, completions,
skill metadata, documentation, dependency/package selection and demonstration
assets. Targeted scans look for common credential formats and personal absolute
paths; absence of those patterns is not proof that no secrets or vulnerabilities
exist. Binary scene inspection disables embedded script execution.

## Local validation results

Environment: Linux x86_64/glibc, Zig 0.16.0, Python 3.14.7, GTK4 4.22.4,
Blender 5.2.1 LTS. These are local results, not a claim about remote CI.

- Baseline and final `zig build check -Doptimize=ReleaseSafe` passed. The final
  run included 28 CLI Zig tests and 125 Python offline tests.
- `zig build pip pip-test -Doptimize=ReleaseSafe` passed, including nine preview
  tests; the private Broadway suite passed both tests.
- Debug Zig tests and the nine isolated keyboard tests passed. Some isolated
  and preview tests overlap other roots; these counts are not additive unique coverage.
- Python compilation, Zig formatting, Bash/shell syntax, `git diff --check`, and
  documentation/package-link validation passed (33 Markdown files at review time).
- A local 0.4.0 ReleaseSafe/baseline x86_64 archive was built and verified with
  `scripts/verify-release.py`; all 37 payload checksums matched. It targets this
  CachyOS/glibc 2.44 build environment, not a universal Linux runtime.
- Both Blender assets reopened with the original object/mesh/material counts
  (14 objects in the original, 278 in the styled scene) and unchanged transforms.
  Embedded console history and old path-buffer contents were cleared. Decompressed
  `.blend` data had no matches for the personal path or checked legacy labels.
  PNG IDAT bytes remained identical after export-metadata removal.
- Targeted current-tree scans covered 119 publication files with no matches for
  the checked private-key, GitHub/API-token, AWS-key or personal-path patterns.
  Scanning 194 historical blobs found two personal-path occurrences and no matches
  for those credential patterns. This is not an exhaustive secrets/security audit.

The final archive contains this updated report after a documentation-only rebuild.
Live desktop control, rendering, and experimental plugin loading were not performed.


## Illustrated README follow-up

The subsequent user-requested examples added four README images and a reproducible
GTK note app. Unlike the initial preparation above, this follow-up exercised native
text and a guarded click in its own managed session, using the explicit local
headless bridge. The result was visually verified; host input stayed disabled.
The optional viewer was captured, closed, and the demonstration session destroyed.
See [image provenance](images/README.md) and [the walkthrough](../examples/gtk/README.md).

The package payload now includes the four images and two example/provenance guides.
The 37-file archive result above describes the earlier package, before those additions.
Documentation links, image payload inclusion, eight packaging regressions, and
Python syntax checks passed for the illustrated update.

## Recorded agent follow-up

A separate agent completed the published prompt in a dedicated managed session
using screenshots, native keyboard input and guarded pointer clicks. It visually
verified both applied notes and stopped input. Host input remained disabled, and
the coordinator destroyed the demo session after recording.

The 244.3-second source recording contains 2,443 captured frames. The edited
46.2-second, 1080p video adds English title cards and command labels and cuts waits;
retained actions run at their original speed. The README links the video, poster,
subtitles, actual task prompt, normalized command transcript and recording/edit
metadata. These final assets are included in the packaging documentation payload.
Raw frames and unredacted logs remain ignored local output. See the
[recording guide](../examples/video/README.md) for provenance and reproduction.

The exported video passed a complete FFmpeg decode and visual checks of the prompt,
actions and final state. It contains a single H.264/yuv420p video stream, fast-start
metadata and no audio stream.

For the combined illustrated/video update, `zig build check pip pip-test
-Doptimize=ReleaseSafe` passed all 30 build steps, 28 CLI Zig tests, nine preview
Zig tests and 125 Python offline tests. Documentation validation covered 36 Markdown
files and package link targets. Python/JSON syntax and the targeted credential/path
scan passed across 125 text files; `git diff --check` also passed. The expanded
archive payload is covered by packaging regressions; the earlier 37-file archive
verification is not a rebuild of this final media payload.
