# Spreadsheet agent demonstration

This example records a real Codex CLI task and a real LibreOffice Calc window
side by side. The coordinator types the [prompt](prompt.txt) into Codex and submits
it. The agent then builds the spreadsheet through deskctl mouse and keyboard input.
The prompt shown on screen is the actual submitted prompt, not an editorial card.

[Animated preview](../../docs/video/spreadsheet-preview.gif) ·
[Full MP4](../../docs/video/spreadsheet-agent-demo.mp4) ·
[English subtitles](../../docs/video/spreadsheet-agent-demo.srt) ·
[Saved spreadsheet](launch-dashboard.ods) ·
[Command transcript](commands.json) · [Edit timeline](edit.json) ·
[Recording metadata](recording.json)

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

1. Install deskctl and LibreOffice Calc. Create a dedicated managed session using
   the [session guide](../../docs/sessions.md).
2. Enable input in that session and launch a blank Calc document there. Launch
   your agent in a terminal and give it deskctl plus an image-viewing tool.
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
requires no download or player click. The MP4 retains a larger, clearer version.
A committed MP4 link alone is not an embedded GitHub video player. Native GitHub
video players use uploaded attachment URLs; an HTML video tag pointing to a Git
file is removed by GitHub's Markdown renderer. See the official
[attachment documentation](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/attaching-files).

## Recording boundaries

The coordinator prepares the blank document and terminal before the recorded
prompt. The agent creates the document using deskctl. Read-only accessibility
inspection is permitted, but direct document APIs and scripted file generation
are excluded from this workflow.

The source recording includes the agent's observations, actions and recoveries.
Failed focus guards reject input; they are not successful document changes. The
published transcript includes error responses as well as successful commands.
The edit timeline identifies retained intervals and playback speed. Crops, labels,
waiting cuts and speed changes are editorial treatments of the real capture.

Temporary package downloads, isolated application profiles, raw frames and
unredacted logs stay in ignored local output. They are not shipped with deskctl.

## Verified run

The recording used Codex CLI 0.153.4 and LibreOffice Calc 26.8.0.3 alongside
deskctl 0.4.0, Hyprland 0.56.2 and Aquamarine 0.15.0. A cursor-inclusive `grim`
capture recorded 9,872 PNG frames over 987.2 seconds at a target of 10 fps. The
agent's 184 forwarded commands include failed help probes and focus guards as well
as successful actions and recoveries. Initial CLI/runtime setup attempts precede
this recording and are excluded.

The MP4 is 88.9 seconds, 1920 × 1080 H.264/yuv420p at 30 fps, with no audio.
The original captured frames are repeated for export; there is no synthetic cursor
or motion interpolation. The terminal and the native prompt submission are visible
at the start. During desktop work, editorial captions cover the terminal, leaving
the actual Calc window visible. Save-dialog footage is omitted to keep personal
paths out. The GIF further condenses the desktop footage to 6× and uses a closer
crop of Calc. Both formats disclose their speed and preserve a final inspection view.

The agent visually checked its result. The coordinator independently inspected all
six monthly ratio formulas, both SUM totals, the aggregate ratio, and the chart's
two six-month series in the saved ODS. The published ODS is an unchanged copy of
the file saved through Calc. Its XML contains no checked personal home path.
The agent stopped input, the coordinator ended capture and destroyed the dedicated
session. The coordinator separately used the host browser for GitHub preparation;
no host desktop footage is included in the demo.

The final MP4 is also uploaded as a GitHub attachment. GitHub's Markdown renderer
was checked for an actual `video` element, not just a download link. Attachment
access follows repository visibility. The GIF and MP4 are also stored in Git for
portable documentation and release-archive inclusion.
