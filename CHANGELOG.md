# Changelog

All notable changes to the `teamwork-tasks-from-session` plugin are documented
in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.2] — 2026-06-11

### Changed

- **Removed the `version` field from the SKILL.md frontmatter** — `plugin.json`
  is now the single source of truth for the plugin version. The frontmatter
  value had silently gone stale at `1.0.0` while the plugin shipped `1.0.1`;
  dropping the field removes that recurring footgun.

## [1.0.1] — 2026-06-10

### Fixed

- **Time logs no longer land hours early / overlap (timezone bug).** `parse_iso`
  parsed the UTC `timeLogged` returned by Teamwork with macOS BSD `date -j -f
  "…Z"` **without `-u`**, reading the wall-clock as local and shifting the logged
  block by the local UTC offset. The BSD `Z` branch now uses `date -ju`. Added a
  **TIMEZONE CONTRACT** note clarifying that `timeLogged` is returned in UTC but
  the POST/PATCH `time` field is interpreted in the user's local timezone — so
  parse UTC (`date -ju`), post local (`date -r`, no `-u`). A no-`Z` `--start`
  value still falls through to the local-aware GNU/Python paths, so it is
  unaffected by the change.

## [1.0.0] — 2026-06-10

### Added

- Initial release. Sibling to `teamwork-task`, `teamwork-task-test`,
  `teamwork-task-analyze`, `teamwork-tasks-from-desk` and
  `teamwork-tasks-from-dnr`.
- **Session → task.** Turns the work done in the current Claude Code session
  into a Teamwork Projects task. Reconstructs what the session accomplished
  from the git commits + working-tree diff made since the session started, the
  changed files, the repo shape, and the live conversation context.
- **Canonical WAME format.** Drafts the main task as
  `[preamble] → HR → ## Akceptačné kritériá → HR → ## Cieľ → HR → ## Technický popis`,
  with a `### Zdroj` footer that records the branch and the session commits.
  The technical section is full Plan-Mode output — same shape as
  `teamwork-task-analyze`.
- **SessionStart hook.** Bundled `hooks/record-session-start.sh` records each
  Claude Code session's wall-clock start into
  `~/.claude/plugins/data/teamwork-task-wamesk/sessions/starts.tsv`. The hook
  writes no context and always exits 0, so it cannot disrupt startup.
- **Layered session-start detection.** `hook → last timelog of the day →
  newest session transcript timestamp → ask`, in that configurable order. The
  detected start is always shown as an editable proposal; `--start=` overrides
  it non-interactively.
- **Real time log.** Logs the session duration back to Teamwork as one
  sequential, non-overlapping, 5-minute-aligned entry (shared rounding logic
  with `teamwork-task`: `round_threshold_minutes`, `min_log_minutes`). The
  logged block is clamped so it never overlaps an existing timelog — it can
  pick up from the end of today's last log instead. Business-tone description
  with an optional `(commit: <hash>)` suffix.
- **Flexible target.** Accepts a project URL (resolves the tasklist, asks when
  there is more than one), a tasklist URL (new main task there), or a single
  task URL (files the session work as a **subtask** of that task). Asks via
  `AskUserQuestion` when no URL is passed.
- **Subtasks.** Proposes 2–6 atomic subtasks only when the estimate exceeds
  240 min and the work has natural cut points; each carries a role prefix
  (`[BE]`/`[FE]`/`[QA]`/`[Migration]`/`[DevOps]`) and its own estimate.
- **Estimate.** WAME senior-engineer-with-Claude-Code methodology — 30–50 %
  speedup, 15–30 % buffer, 15 min step, 480 min cap per task.
- **Clarifying questions.** Batched `AskUserQuestion` (up to 4 per batch, up to
  6 per run); answers folded into AC / Cieľ / Technický popis; unresolved
  preserved as `[OTVORENÉ]` markers.
- **Preview + confirmation gate.** Renders the full concept *and the exact
  time-log entry* before any write; `--write-back=never` stops here as a full
  dry-run (nothing created, no time logged).
- **Board action asked per run.** After creating the task the skill asks what
  to do with the board state — leave it, move `In progress → Internal testing`,
  or mark the task complete (default `board.after_create = ask`).
- **Hardened Projects writes** (carried over from the `teamwork-tasks-from-desk`
  field lessons): Python-encoded JSON payloads (`ensure_ascii=False`) for
  multi-line Slovak descriptions, the `estimatedMinutes` **write** field (not
  the read-only `estimateMinutes`), and an idempotency guard that searches the
  tasklist by name before retrying a POST.
- **Shared config.** Reuses `~/.claude/plugins/data/teamwork-task-wamesk/config.json`
  and the family's Projects token; adds a `session_skill.*` namespace.
- **Run-duration report + history TSV.** Each run appends to
  `~/.claude/plugins/data/teamwork-task-wamesk/runs.tsv` for later comparison.
- **Boundaries.** Never runs git, never logs time without confirmation, never
  writes an overlapping time log, never silently overwrites an estimate, never
  moves the board or completes the task without asking.
