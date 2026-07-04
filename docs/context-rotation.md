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

Telemetry currently supports Claude Code footer fixtures like:

```text
Fable 5 | fusor ████████░░ 89%
```

The real footer uses a box separator; the parser accepts that form too.
Codex is intentionally unsupported until a real installed-TUI footer format is verified.
The installed `codex-cli 0.142.5` help output does not document a footer contract; the local user config has `show-context-window-usage = true`, but no stable rendered pane line was verified for this implementation.
Reported formats such as `NN% context left` would need adapter code that converts remaining context into fullness.

`bin/fm-rotate.sh <id>` performs the crew restart.
It requires a committed handoff/stow document (or `--handoff <path>` naming one), refuses any still-dirty worktree before exiting/relaunching, exits the old harness session with the verified adapter command, waits for backend-specific evidence that the endpoint has returned to a shell in the task worktree, then launches a fresh harness process in the same endpoint, same worktree, and same branch with a continuation prompt pointing at the handoff.
If no committed handoff exists, it sends the crew a handoff request and waits up to `FM_ROTATE_WAIT_SECS` seconds (default `900`) for the handoff to be committed, the worktree to become clean, and the crew to return to a non-busy boundary.
Set `FM_ROTATE_WAIT_SECS=0` when a supervisor needs the request-only behavior; that exits `3` after sending the handoff request.

## Firstmate Itself

Firstmate self-rotation is the same method:

```text
/stow
exit
```

Start firstmate through `bin/fm-run.sh`.
The wrapper relaunches a fresh harness session after the previous one exits and backs off when the session exits too quickly.
Use `--harness <name>` or `-- <command...>` to choose the exact harness command.

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
