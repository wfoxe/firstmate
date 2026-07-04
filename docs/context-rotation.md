# Context Rotation

Firstmate's rotation policy is stow, then restart.
At or above `FM_ROTATE_THRESHOLD` context fullness (default `70`), a session must preserve durable state and continue in a fresh session, but only at a turn boundary.
Rotation never interrupts a busy agent.

## Crew Sessions

`bin/fm-watch.sh` reads context telemetry only on turn-boundary paths: changed `state/<id>.turn-ended` markers and first-sighting stale panes.
If the crew is still provably working (`fm-crew-state.sh` reports an active run-step or busy pane), no rotation wake is emitted.
If the crew is not busy and its verified context fullness is at or above the threshold, the watcher queues:

```text
rotation-due: <id> <pct>%
```

The wake is suppressed by task, percentage, and turn-boundary signature, so one high-context boundary does not repeat until pane or turn state changes.
Unsupported or unparseable telemetry is silent.

Telemetry currently supports the owner's local Claude Code statusline, not a
built-in Claude footer. The verified local statusline renders fixtures like:

```text
Fable 5 | fusor ████████░░ 89%
```

The real statusline uses a box separator; the parser accepts that form too and
requires a separator before the context bar so unrelated progress bars such as
`Downloading model ██████████ 100%` do not count as context telemetry.
Homes without that custom Claude statusline simply have no telemetry and do not
emit rotation wakes.
Codex is intentionally unsupported until a real installed-TUI footer format is verified.
The installed `codex-cli 0.142.5` help output does not document a footer contract; the local user config has `show-context-window-usage = true`, but no stable rendered pane line was verified for this implementation.
Reported formats such as `NN% context left` would need adapter code that converts remaining context into fullness.

`bin/fm-rotate.sh <id>` performs the crew restart.
It requires a committed handoff/stow document (or `--handoff <path>` naming one) that is newer than the previous recorded rotation, refuses any still-dirty worktree before exiting/relaunching, exits the old harness session with the verified adapter command, waits for backend-specific evidence that the endpoint has returned to a shell in the task worktree, then launches a fresh harness process in the same endpoint, same worktree, and same branch with a generated `data/<id>/rotation-prompt.md` continuation prompt pointing at the handoff.
After the fresh harness launch starts, it appends `rotation_handoff=` and `rotation_at=` to the task meta; older handoff docs are ignored on later rotations unless a fresh committed handoff is supplied.
That verified relaunch path currently supports tmux and herdr endpoints only.
Zellij and Orca tasks do not emit `rotation-due` wakes until their adapters expose a passive, verified shell-readiness check after harness exit.
Secondmates are excluded from parent-side `fm-rotate.sh` because their durable stow lives in their own firstmate home, not in a committed task worktree artifact.

If no committed handoff exists, the foreground-safe default is request-now/rerun-later: `fm-rotate.sh` sends the handoff request and exits `3`.
Re-run it after the crew reports that a fresh committed handoff exists.
For a harness-tracked background wait, set `FM_ROTATE_WAIT_SECS` to a positive value; the script then waits for the committed handoff, a clean worktree, an empty composer, and a fresh pane capture with no busy signature before sending `/exit`.

## Firstmate Itself

Firstmate self-rotation is the same method:

```text
/stow
exit
```

Start firstmate through `bin/fm-run.sh`.
The wrapper relaunches a fresh harness session after the previous one exits, carrying a startup prompt that runs `bin/fm-session-start.sh` and resumes supervision.
It backs off when the session exits too quickly.
Use `--harness <name>` or `-- <command...>` to choose the exact harness command; `--once` runs one launch without the restart loop for tests or smoke checks.
To stop instead of rotate, create `state/.fm-run-stop` (or set `FM_RUN_STOP_FILE`) before exiting the harness; the wrapper exits instead of relaunching.

Claude Code 2.1.193 documents `PreCompact` and `PostCompact` hooks in its official hook reference, but not a context-threshold hook.
An optional local Claude settings hook can therefore only remind before compaction, not enforce the 70% policy:

```json
{
  "hooks": {
    "PreCompact": [
      {
        "matcher": "auto|manual",
        "hooks": [
          {
            "type": "command",
            "command": "printf '%s\n' '/stow then exit' >&2"
          }
        ]
      }
    ]
  }
}
```

Do not commit this hook by default.
It belongs in the operator's local Claude settings if they want the reminder.
