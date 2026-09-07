# Recorded agent demo

This is a real, silent, captioned recording of a Codex subagent operating the
included GTK note app through deskctl. The coordinator prepared an empty demo
window, started screen capture, and sent the [task prompt](prompt.txt) to a separate
agent. The agent inspected screenshots, chose coordinates, typed both notes,
clicked **Apply text**, verified the visible results, and stopped input.

[Watch or download the MP4](../../docs/video/deskctl-agent-demo.mp4) ·
[English subtitles](../../docs/video/deskctl-agent-demo.srt) ·
[Command transcript](commands.json) · [Edit timeline](edit.json)

## What is real, and what was edited

- The application footage is captured from a dedicated managed Hyprland session.
  Text, cursor movement, button clicks and result labels are actual application
  behavior. The agent did not modify the sample's source or call widget APIs.
- The opening title card reproduces the task prompt that was sent to the agent.
  It is an editorial card, not a screenshot of a chat interface. The execution
  instructions additionally specified the existing session, command recorder,
  screenshot review, and prohibition on host input or application API shortcuts.
- Titles and command labels were added in the editor. Labels replace volatile
  window addresses and frame IDs with `<observed>`; action text is unchanged.
- Waiting intervals between actions are removed with cuts. Retained screen
  intervals play at **1×**, including the cursor approaches. The recording used
  10 screenshots per second; the export is 30 fps using repeated frames, without
  motion interpolation or a synthetic cursor.
- There is no voiceover, music, or reconstructed application state. The application
  stays open after `stop`; the coordinator destroys the test session after recording.

## Reproduce the task

Follow the [GTK walkthrough](../gtk/README.md) to create a disposable session and
launch `examples/gtk/note.py`. Give an agent the text in `prompt.txt`, together with
the actual managed session name and access to deskctl and an image-viewing tool.
Require it to inspect fresh screenshots and verify both applied results. Do not
copy the recording's coordinates or frame IDs into your session.

The public [command transcript](commands.json) was generated from the actual
forwarded commands and successful CLI responses. Times are seconds from the start
of the raw recording, not from the edited video's opening. Window/frame identifiers
are normalized; screenshot paths, local environment and unrelated desktop data are
omitted. The transcript records delivery; the screenshot evidence provided the
application-result verification.

## Recording and export

Environment: deskctl 0.4.0, Hyprland 0.56.2, Aquamarine 0.15.0, GTK4 4.22.4, a
1280 × 720 managed output and the explicitly selected local headless format bridge.
The host input token remained disabled. See [compatibility](../../docs/compatibility.md)
for why this setup is not universal GPU support or a filesystem sandbox.

The coordinator captured cursor-inclusive PNGs with `grim` against the exact child
Wayland socket and retained a monotonic timestamp for each frame. A transparent
wrapper recorded command arguments/results before forwarding them to the real
built CLI. FFmpeg assembled frame durations, cut waits, added the title/command
panels, and exported H.264/yuv420p with fast-start metadata for playback.

[Recording metadata](recording.json) records the output properties, source counts,
and checksums. `edit.json` maps retained source intervals into the finished video.
The raw images and unredacted command log remain local in ignored
`output/agent-video/`; they are not included in Git or release archives. The final
MP4, poster, subtitles, normalized transcript and provenance are committed.

This demonstration verifies the small note workflow. It does not establish
compatibility with every application or prove that an agent always chooses the
correct action.
