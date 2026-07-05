---
name: stow
description: Sweep the current conversation for durable knowledge - user preferences, project facts, operational gotchas, and unfinished next steps - then file each through explicit instructions, existing local conventions, or the private `.stow-notes.md` fallback, and occasionally prune/compress local notes so they stay lean. Use when the user invokes /stow, asks to save or write down what was learned this session, asks to prune stowed memory, or before a context reset or long break.
user-invocable: true
---

<!-- maintainers: this is the public, installer-facing skill. Keep it standalone, with no private project paths, tool assumptions, or environment branching. -->

# stow

Sweep this conversation for durable knowledge that only exists in chat right now, and write it through the user's explicit instructions, this project's existing local conventions, or the private `.stow-notes.md` fallback in the current directory.
The goal is a conversation that is safe to end, reset, or hand off because everything durable has already been captured on disk, not left stranded in the transcript.
Everything this skill files goes to a local file by default; it only ever reaches an external system such as an issue tracker when you have explicitly said to use one.

## What it does

1. **Sweep the conversation for uncaptured durable knowledge.**
   Read back over the session and look for:
   - User preferences: a working-style, tooling, formatting, or approval preference the user stated in passing rather than through a config file.
   - Project facts: build, test, deploy, architecture, or convention facts about the current project that would help anyone (or any agent) working in it later.
   - Operational gotchas: a sharp edge, workaround, recurring mistake, or non-obvious cause discovered while working here.
   - Undone next steps: anything left open or agreed to that has not yet been written down anywhere.

2. **Discover the host's existing conventions before deciding where anything goes.**
   Don't assume a destination - look for what's actually there, roughly in this order:
   - A project-level memory file, such as `CLAUDE.md`, `AGENTS.md`, or an equivalent at the repo root or nearby.
   - A user-level (global) memory file the running agent reads across projects, if one exists and is readable.
   - A `TODO`, `BACKLOG`, `NOTES`, or similarly named plain file already tracked in the project.
   This step is about local files only, not remote systems.
   Do not scan for or infer an issue tracker here - see the priority order in step 3.

3. **Route each finding using this fixed priority order, local-first.**
   1. **Highest - an explicit instruction wins.** If the user has explicitly said, earlier in this conversation or as a standing choice previously recorded in the discovered user-level memory file (see step 4), to use a particular system for this kind of finding - including an external tracker - route it there.
      This is the *only* path to an external or public system: an issue tracker, a hosted project board, a ticketing system, or similar.
      A configured git host remote, a `.github/`/`.gitlab/` folder, or any other signal that a tracker probably exists is never by itself grounds to file anything there - never route externally on inference.
   2. **Otherwise - the local system the user already uses.** Route to whatever local memory/backlog convention this project or user already has for that kind of finding: the discovered project memory file (`CLAUDE.md`/`AGENTS.md`) for project facts and operational gotchas, an existing `TODO`/`BACKLOG`/`NOTES` file for undone next steps, or a discovered user-level memory file for user preferences *when one happens to be accessible* - a global memory file is a bonus if the running agent can reach one, never an assumption or a requirement.
      Among local durable-finding writes, this tier is the only one that writes findings into a tracked, shared file, and the only one that may write outside the current directory - it only fires when that destination was already an established convention the user (or their agent) already has access to, never a path this skill invents itself.
   3. **Fallback - the default prescribed private file, in the current directory.** If no existing local convention fits, don't improvise a location or invent an ad hoc filename.
      Before writing it in a git worktree, verify that `.stow-notes.md` is not already tracked in the index.
      If it is tracked, do not append private findings there, do not describe it as private, and report that the tier-3 fallback is blocked until the user chooses a safe destination.
      In a non-git directory, treat this as a local private file by filesystem scope.
      After the tracked-file check passes, create or append to `.stow-notes.md` in the current directory, for every finding-kind including user preferences.
      This file always lives inside the current working directory, never a user-level or home-directory path, so the fallback works even for agents sandboxed to the current directory.
      Then keep it out of git: create or append a `.stow-notes.md` line in a `.gitignore` file **in the current directory** - an ordinary file at that path, so this stays fully in-directory even inside a linked worktree, unlike git's internal exclude mechanism, which can resolve outside the working directory there.
      Leave staging or committing that `.gitignore` line to the user, same as everything else this skill writes.
      If even the `.gitignore` write fails, don't block or error - still create `.stow-notes.md` and tell the user to ignore it manually.
   Tiers 2 and 3 are always local; only tier 1 - an explicit instruction - ever reaches an external or public system.
   Tier 2 is the only tier that lands durable findings in a tracked/shared file; tier 3 keeps stowed findings in the private `.stow-notes.md` file only after confirming it is not already tracked, and confines any optional `.gitignore` metadata edit to the current directory.

4. **When it's genuinely ambiguous between two existing conventions, ask once - then remember the answer.**
   If more than one discovered local convention plausibly fits a finding, ask the user once, plainly, which one they want that kind of note to live in going forward.
   The same applies if the user gives an explicit instruction to use a tracker or other non-local system going forward rather than just for one item right now.
   Once they answer, offer to remember it for next time: with their explicit permission, record a short standing note of that choice in the discovered (or newly agreed) user-level memory file, so the same question - or the same tracker instruction - doesn't need to be repeated in this project.
   Always ask before adding that note - never establish the convention silently on your own judgment.
   When nothing existing fits at all (not merely ambiguous), that's tier 3, not this step - use the `.stow-notes.md` fallback from step 3 instead of asking, for any finding-kind.

5. **Write only into locations that already exist as a real convention, the `.stow-notes.md` fallback from step 3 (plus its line in a current-directory `.gitignore`), or a destination the user just approved in step 4.**
   Do not invent new shared files, new folders, or new tracker categories the project doesn't already have, and do not pick an ad hoc filename or location for the fallback - `.stow-notes.md` in the current directory is the one prescribed default.
   If even that fallback is unwritable and the user doesn't want to establish a new convention, say so plainly and leave that finding unfiled rather than fabricate a destination for it.

6. **Run lightweight note hygiene when the gate says to.**
   This keeps local stow destinations from accumulating stale prose over long use, while ordinary `/stow` runs stay cheap.
   Because this public skill has no fixed firstmate home and must stay sandbox-safe, the phase is limited to local files this skill just wrote or selected as destinations, especially `.stow-notes.md`.
   Do not scan unrelated files looking for something to prune.

   Full hygiene runs only when at least one trigger fires:
   - **Size budget exceeded:** a local stow destination is over its budget.
     Use 60 lines for `.stow-notes.md`.
     For an existing project or user memory file, use its documented local budget if one exists; otherwise treat "obviously sprawling and repetitive" as a judgment trigger instead of imposing a universal budget on someone else's convention.
   - **Staleness:** more than 7 days since the last hygiene pass for the current-directory fallback.
     Track that with `.stow-last-hygiene` in the current directory, written as an ISO date (`YYYY-MM-DD`) after a pass.
     If the timestamp is absent and `.stow-notes.md` exists, treat it as stale once so the fallback gets a baseline pass.
     Before writing it in a git worktree, verify that `.stow-last-hygiene` is not already tracked in the index.
     If it is tracked, do not create or update it as private metadata, do not rely on `.gitignore` to protect it, and report the hygiene timestamp write as blocked until the user chooses a safe destination or confirms the tracked file is acceptable.
     After the tracked-file check passes, protect it the same way as `.stow-notes.md`: add a `.stow-last-hygiene` line to the current-directory `.gitignore` when possible, and report if the ignore write failed.
     If `.stow-notes.md` does not exist and no current-directory fallback was used, skip this timestamp entirely.
   - **Explicit request:** `/stow prune`, "prune memory", or an equivalent user request forces a pass over the relevant local stow destinations.

   When no trigger fires, do not reread or rewrite everything.
   Print one short status line such as `local stow notes within budget, last pruned 2026-07-04` and skip the phase.
   When a trigger fires, run the checklist below and write today's ISO date to `.stow-last-hygiene` after the tracked-file check passes, if the current-directory fallback is part of the pass.

   Prune checklist:
   - Delete entries that are superseded, disproven, or expired; keep dates on what survives when dates are already part of the convention.
   - Consolidate clusters: several entries about one topic should become one rewritten durable entry.
   - Re-route misfiled knowledge to the most specific existing local convention from step 3; never move anything to an external system unless explicit instructions already allow that route.
   - Tighten prose without losing load-bearing facts, active constraints, or the "why" behind preference and feedback entries.
     When in doubt, consolidate rather than delete.
   - Never prune away standing user instructions, safety tripwires, active access constraints, never-reenable rules, or anything the user marked important.
     These may be compressed, but the operative instruction must survive.

7. **Curate, don't just append.**
   When a finding overlaps or supersedes something already recorded, prefer editing or replacing the existing note over piling on a duplicate.

8. **Finish with an honest safe-to-end verdict and a resume pointer for the next session.**
   Tell the user, in plain language, what was captured and where, what could not be captured (and why), and whether the conversation is now safe to end or reset - i.e. whether every durable finding from this sweep now lives on disk or in an explicitly requested tracker rather than only in this chat.
   Include the one-line note-hygiene result: skipped within budget, pruned specific files, or unable to prune with the reason.
   If something could not be captured yet, say so explicitly instead of reporting the session fully safe.
   If anything landed in the `.stow-notes.md` private fallback, say so explicitly - note that it is private and confined to this project, and that it can be promoted into a shared, tracked file later if the user wants it more widely visible.
   In a git repo, report the ignore protection according to what actually happened: if the `.gitignore` write succeeded, say that a `.stow-notes.md` line was added to a current-directory `.gitignore` to keep it out of git, awaiting the user's own commit; if the `.gitignore` write failed, say that `.stow-notes.md` was still written but the user must ignore it manually before relying on git to hide it from status or commits.
   If the tier-3 fallback was blocked because `.stow-notes.md` was already tracked, say that no private fallback was written and that the session is not fully safe to reset until the user chooses another destination or confirms that tracked file is acceptable.
   If the hygiene timestamp write was blocked because `.stow-last-hygiene` was already tracked, say that no private timestamp was written and that timestamp-based hygiene remains blocked until the user chooses another destination or confirms that tracked file is acceptable.
   If a user preference specifically landed there because no user-level memory file was discovered, add the one extra caveat: it now applies to this project only; this skill's own tier-3 default never writes outside the current directory, so if the user wants that preference to follow them across every project, they need to copy it into their own global/user-level memory file themselves.
   The real payoff of stowing is not this session, it's the next one: close with a short, copy-pasteable RESUME POINTER naming exactly which files a fresh session should load to pick this back up cold, e.g. `To pick this back up in a new session, load: CLAUDE.md (project conventions), .stow-notes.md (private notes, not shared)`.
   List only the files this sweep actually wrote or updated; skip the pointer if nothing was written.

## What this skill does not do

It does not invent a new note-taking system, initialize version control, or commit/push anything on the user's behalf beyond editing a file the discovered convention already made writable, creating the `.stow-notes.md` fallback from step 3 and its untracked `.stow-last-hygiene` timestamp plus their lines in a current-directory `.gitignore`, or using a destination the user explicitly approved.
It never stages or commits those `.gitignore` lines itself - the edit lands in the working tree only, for the user to review and commit like any other change.
Its own tier-3 default never writes durable findings outside the current working directory, and its optional `.gitignore` metadata edits are also confined to that directory.
Among local durable-finding writes, tier 2 is the only exception, and only because it targets a destination the user's own existing convention already established, never one this skill invents.
It never files credentials, secrets, or other sensitive material - only knowledge that's safe to keep in plain text wherever it lands.
It never files anything to an issue tracker, hosted board, or other external/public system on its own inference - that only ever happens on the user's explicit say-so, per the hard rule in step 3.
