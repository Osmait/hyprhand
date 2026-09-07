# Spreadsheet agent demonstration

The demo combines a newly recorded **Hyprhand** prompt submission in Codex CLI
with the original real LibreOffice Calc workflow. The introduction was refreshed
for the project rename; the spreadsheet execution was not recorded again.

[Animated preview](../../docs/video/spreadsheet-preview.gif) ·
[Full MP4](../../docs/video/spreadsheet-agent-demo.mp4) ·
[English subtitles](../../docs/video/spreadsheet-agent-demo.srt) ·
[Saved spreadsheet](launch-dashboard.ods) ·
[Original command transcript](commands.json) · [Current edit timeline](edit.json) ·
[Current recording metadata](recording.json)

## Refreshed Hyprhand introduction

At the owner's request, only the beginning was re-recorded after deskctl became
Hyprhand. The coordinator typed the [updated prompt](prompt.txt) into an actual
Codex CLI window using Hyprhand native keyboard input, then pressed Return.
The visible prompt and submission are real terminal captures. A dedicated
introduction-only session was instructed to acknowledge the prompt without
running a second spreadsheet task. The session was stopped and destroyed after
capture.

The edit joins that new take to the original Calc execution segments. Those
segments are reused without changing their application footage, command results,
or playback speed. The GIF identifies the new introduction and the original
workflow. This is an edited demonstration assembled from two takes, not one
continuous agent run. The original desktop run used the former deskctl name.

The [original prompt](prompt-original.txt), [original edit timeline](edit-original.json),
[original recording metadata](recording-original.json), and command transcript
preserve the execution evidence. Paths and checksums inside the original metadata
refer to the files at commit `72b61dd83153fe5d21671d88bed20fe905270b03`, before this
intro refresh. Current media checksums are in `recording.json`.

## Task and data

The task is a launch dashboard using fictional demonstration data. No customer,
company or account data is used. The input table is also available as
[data.csv](data.csv).

| Month | Signups | Target |
| --- | ---: | ---: |
| Jan | 120 | 100 |
| Feb | 180 | 150 |
| Mar | 260 | 250 |
| Apr | 340 | 300 |
| May | 460 | 400 |
| Jun | 620 | 500 |

Achievement means signups divided by target. The independent control totals are
1,980 signups and a target of 1,700, giving 116.47% overall achievement. The overall
rate uses the totals, not the average of the six monthly percentages.

## Reproduce

1. Install hyprhand and LibreOffice Calc. Create a dedicated managed session using
   the [session guide](../../docs/sessions.md).
2. Enable input in that session and launch a blank Calc document there. Launch
   your agent in a terminal and give it hyprhand plus an image-viewing tool.
3. Give the agent the included prompt and your actual session name. Require fresh
   screenshot inspection before pointer actions. Do not reuse recorded coordinates
   or frame/window identifiers.
4. Require all document creation, formatting, formulas, chart insertion and saving
   to happen through the application UI. Spreadsheet APIs, macros and file generation
   would demonstrate a different workflow.
5. Verify the visible totals and chart, save the document, and stop input. Destroy
   only the session you created once the demonstration is finished.

The recorded environment uses LibreOffice Calc rather than Google Sheets. It needs
no Google login. Managed sessions isolate input, not files, credentials or network
access. The recording uses the explicitly selected local headless bridge described
in [compatibility](../../docs/compatibility.md).

## README playback

GitHub renders the short GIF directly as an animated image in the README, so it
requires no download or player click. The README intentionally uses only the GIF.
The MP4 remains available from this recording guide as a larger, clearer version.
A committed MP4 link alone is not an embedded GitHub video player. Native GitHub
video players use uploaded attachment URLs; an HTML video tag pointing to a Git
file is removed by GitHub's Markdown renderer. See the official
[attachment documentation](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/attaching-files).

## Recording boundaries

In the original run, the coordinator prepared the blank document and terminal
before the recorded prompt. The agent created the document using deskctl.
Read-only accessibility inspection is permitted, but direct document APIs and scripted file generation
are excluded from this workflow.

The source recording includes the agent's observations, actions and recoveries.
Failed focus guards reject input; they are not successful document changes. The
published transcript includes error responses as well as successful commands.
The edit timeline identifies retained intervals and playback speed. Crops, labels,
waiting cuts and speed changes are editorial treatments of the real capture.

Temporary package downloads, isolated application profiles, raw frames and
unredacted logs stay in ignored local output. They are not shipped with deskctl.

## Verified original spreadsheet run

The recording used Codex CLI 0.153.4 and LibreOffice Calc 26.8.0.3 alongside
deskctl 0.4.0, Hyprland 0.56.2 and Aquamarine 0.15.0. A cursor-inclusive `grim`
capture recorded 9,872 PNG frames over 987.2 seconds at a target of 10 fps. The
agent's 184 forwarded commands include failed help probes and focus guards as well
as successful actions and recoveries. Initial CLI/runtime setup attempts precede
this recording and are excluded.

The refreshed MP4 keeps the original desktop segments at 2× and the GIF keeps
those segments at 6×. Both retain the final inspection view. The MP4 uses
1920 × 1080 H.264/yuv420p at 30 fps with no audio; the GIF uses 960 × 800 at a
target of 8 fps and loops automatically. See `recording.json` for exact durations
and sizes. There is no synthetic cursor or motion interpolation. Editorial
captions cover the terminal during desktop work, and the original save-dialog
footage is omitted to keep personal paths out.

The agent visually checked its result. The coordinator independently inspected all
six monthly ratio formulas, both SUM totals, the aggregate ratio, and the chart's
two six-month series in the saved ODS. The published ODS is an unchanged copy of
the file saved through Calc. Its XML contains no checked personal home path.
The agent stopped input, the coordinator ended capture and destroyed the dedicated
session. The coordinator separately used the host browser for GitHub preparation;
no host desktop footage is included in the demo.

An earlier edit was uploaded as a GitHub attachment. That historical attachment
is not used by the current README, which displays only the refreshed GIF. The
refreshed MP4, subtitles, GIF, prompt and metadata are stored in Git and included
in documentation archives.
