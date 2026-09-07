# Performance and reliability — September 2026 follow-up

Historical base: `cd500ce` (`main`), Zig 0.16.0, Linux, ReleaseSafe.
This follow-up used no desktop or host sockets. Synthetic timings include Python
fixture servers/helpers and do not measure Hyprland, GPU, or real application latency.

## Reliability fixes

- **Stop without new writes.** Enable publishes a generation before querying the
  compositor. Stop removes generation, token and indicator under the authority
  lock, attempting every revocation even if one fails. A regression using
  `RLIMIT_FSIZE=0` verifies later input rejection and invalidation of an earlier
  concurrent enable. Directory permissions, kernel failure or inability to unlink
  can still prevent revocation.
- **Nonblocking Wayland event waits.** Synchronization uses prepare/read/cancel,
  preserves its deadline and checks cancellation. Regressions cover incomplete
  messages, timeout, SIGTERM and injected real flush `EAGAIN`. Already queued input
  keeps its independent cleanup path.
- **Recoverable audit log.** Full writes are retried, failed writes roll back a
  partial tail where possible, and subsequent appends recover an uncommitted line.
  `logs` reports `incomplete_tail` and parses only the requested recent records.
  Typed text and titles are excluded.

## Optimizations

- One full guard per character; only the immediately following synchronization
  can reuse it. Waiting for another iteration triggers validation again. There
  is no cross-character authorization cache.
- Reusable guard arenas retain at most 256 KiB; motion memory is bounded per
  sample. Focus, lock, layout, PID-owned aura exclusion and cursor checks remain.
- A fixed 4 KiB JSON output buffer prevents retained event strings. A regression
  streams 4096 records of 60 KB under a 128 MiB virtual-memory cap. The 64 KiB
  event limit applies per record, permitting adjacent large records in one read.
- Automatic screenshot cleanup scans at most once every 30 s. Explicit GC always
  scans, and neither removes still-usable frames.
- A persistent preview worker allows at most one outstanding request. `grim`
  still starts per capture, but the CLI no longer starts per frame. Session and
  identity are checked before/after capture; memory is freed between requests.
- Cancelable I/O and texture decoding run off the GTK thread. Lengths are bounded
  before allocation, PNG slices share storage, and identical textures are reused.
  Unchanged images back off to 1 fps; changes restore the requested rate.
- Opt-in telemetry distinguishes captures, new textures, GTK paints and confirmed
  GDK presentation timestamps. Live benchmarks include active persistent workers
  as well as reaped children.

## Offline comparison

Before medians came from the prior audit with four samples per text length;
after medians came from the reproducible script with five. IPC counts are the
more stable comparison. The binaries were not alternated under identical load.

| Typed text | IPC before → after | Median before → after |
| --- | --- | --- |
| 16 characters | 74 → 42 | 6.60 → 5.33 ms |
| 128 characters | 522 → 266 | 27.54 → 16.80 ms |
| 1024 characters | 4134 → 2086 | 195.80 → 100.23 ms |

With 1 ms artificial query delay, 128 characters changed from 568.14 ms
(three samples) to 291.48 ms (five).

For 60 KB events, prior peak RSS grew from 18,664 KiB at 10 events to 65,792 KiB
at 1000. Afterward both lengths recorded 23,636 KiB. `wait4.ru_maxrss` can include
an inherited pre-exec peak; absence of proportional growth matters more than
comparing absolute floors between Python invocations. The bounded-memory regression
is independent of those RSS samples.

```sh
zig build check pip pip-test -Doptimize=ReleaseSafe
python3 tests/viewer_broadway.py
python3 scripts/benchmark_offline.py --samples 5
python3 scripts/benchmark_viewer_offline.py --seconds 300
```

Optional GTK tests use private Broadway Unix sockets and a valid synthetic PNG.
They check texture reuse, signal loss/recovery, and closure during capture even
when grim ignores TERM. They require no browser or host window and do not verify
physical Wayland presentation. An initial long run was discarded because fake
source processes expired after 60 s; the fixture was extended beyond the benchmark,
and any signal loss now invalidates results.

The valid run lasted **300.12 s** after 5 s warmup, at a maximum requested 15 fps:
**2.28% of one core** for viewer/workers, viewer RSS **85.41 MiB** initially and
finally, with no variation in 5 s samples. It received 327 fresh responses including
warmup and created one texture; the static source settled near 1 capture/s.
Closure was normal with no surviving owned processes. Five-minute stability is
not hours-long leak certification or physical monitor fps measurement.

## Live verification still needed

Direct comparison with the earlier 51–77% single-core PiP figures is **invalid**:
those runs used Hyprland/NVIDIA; these used Broadway and synthetic helpers.
Repeat the opt-in benchmark on the same GPU with moving video and hours-long runs.
The script accepts up to one hour, never enables control, and opens its own host
PiP when `--live` is selected.

PipeWire/zero-copy and eliminating grim need a different backend and remain
unimplemented. Monitor-change placement, managed XWayland, and other GPU limitations
from the prior report were outside this follow-up.
