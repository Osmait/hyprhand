# Moving from deskctl to Hyprhand

The project is now **Hyprhand**, and the CLI command is `hyprhand`. This is a
project-wide rename: commands, installation paths, shell completions, the agent
skill, optional helpers, and runtime namespaces use the new name. The command
structure and JSON contract are unchanged. The source version remains 0.4.0.

| Previous name | Current name |
| --- | --- |
| `deskctl` | `hyprhand` |
| `deskctl-pip` | `hyprhand-pip` |
| `share/deskctl/skills/deskctl` | `share/hyprhand/skills/hyprhand` |
| `$deskctl` agent skill | `$hyprhand` agent skill |
| `DESKCTL_*` environment variables | `HYPRHAND_*` environment variables |
| `deskctl-outline.so` / `deskctl:outline` | `hyprhand-outline.so` / `hyprhand:outline` |
| `deskctl-headless-formats.so` | `hyprhand-headless-formats.so` |
| `computer-use-hyperland` repository | `hyprhand` repository |

## Upgrade an existing installation

1. Before replacing the old binary, run `deskctl sessions` in the original
   host environment. Stop input with `deskctl stop --session host` and
   `deskctl stop --session NAME` for each managed session. Save work and destroy
   only sessions you own with `deskctl session destroy NAME`. Close old previews.
2. Build and install Hyprhand using the [installation guide](../README.md#build-and-install).
   The install step does not remove old binaries, completions, skill links, or
   optional libraries. Remove those old installation files once you have finished
   using the old sessions. No compatibility alias is installed.
3. Update scripts to call `hyprhand`, update any explicitly configured
   `DESKCTL_*` variables to `HYPRHAND_*`, and install/link the renamed agent skill.
   Reload your shell's completions. Optional viewers must be rebuilt and installed
   as `hyprhand-pip` beside the new CLI.
4. If you opted into an experimental bridge, rebuild it and update its explicitly
   configured path. Do not mix the renamed outline dispatcher with an old plugin.
   See the [experimental bridge guide](experimental-bridges.md).
5. Run `hyprhand doctor --session host`. Create new managed sessions as needed,
   inspect their state, and explicitly enable input when ready.

Runtime state is not migrated. Hyprhand uses `hyprhand-sessions` and
`hyprhand-*` directories under `XDG_RUNTIME_DIR`, so it does not discover or stop
old deskctl sessions and does not inherit old input permissions. Do not delete
an old session directory while its compositor is running; use the old CLI to
clean up the session first. Updating the name does not stop a running old process.

For an existing Git checkout, update its remote with:

```sh
git remote set-url origin https://github.com/Osmait/hyprhand.git
```

The local checkout directory can keep its existing name.

## Recordings and screenshots

The published demos were recorded before the rename. Original screenshots,
videos, subtitles, submitted prompts, transcripts, recording metadata, and saved
artifacts remain unchanged to preserve the evidence of what actually ran.
They may show `deskctl` or refer to the former application ID
`org.deskctl.NoteDemo`. New GTK demo runs use `org.hyprhand.NoteDemo`.

When reproducing a historical prompt, replace command references to `deskctl`
with `hyprhand` and use fresh session names, observations, and window identifiers.
Current walkthroughs already use the new command. The Blender styling script
recognizes the original `deskctl_style` object marker as well as the new
`hyprhand_style` marker so that older generated objects can still be cleaned up.
