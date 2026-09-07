# Historical evidence

These reports describe specific versions, machines and past test runs. They are
retained because the current compatibility and implementation guides cite their
findings. Test counts, timings and open items are historical; they do not establish
current CI status or universal compatibility. Commands in a report may need adapting
to the current checkout. Start with the [current guides](../README.md) for usage.

| Report | Why it is retained |
| --- | --- |
| [Initial September audit](audit-2026-09.md) | Reproduced IPC, cancellation and cleanup failures |
| [Audit follow-up](audit-followup-2026-09.md) | Live session checks, initial PiP measurements and platform limits |
| [Performance follow-up](performance-2026-09.md) | Offline comparisons and persistent-worker measurements |
| [0.4.0 reliability](reliability-040.md) | Application-observed pointer, modifier and scroll behavior |
| [Hidden-workspace probe](background-probe.md) | Evidence that separate workspaces do not isolate keyboard input |
| [Cursor capture probe](cursor-outline-probe.md) | Why native cursor capture did not supply a usable outline |
| [Experimental bridge hardening](experimental-hardening.md) | ABI guards, GL resource handling and validation limits |
