# Changelog

All notable changes to the `teamwork-tasks-from-session` plugin are documented
in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] — 2026-09-22

### Changed
- **Estimate methodology replaced — `wame-estimate-v2`.** The old rule produced a
  "traditional" estimate, cut it by 30–50 % for Claude Code, then added a 15–30 %
  buffer on top. Two percentages stacked on a guess give a 0.58×–0.91× band on
  every task, so the same work could legitimately be quoted at 60 or at 95
  minutes and the wider end always won the argument. The methodology now
  estimates **one number directly** against a table of finished-outcome anchors.
  The anchors are tighter (a single figure each, adjust by at most one 15-minute
  step) and the block states explicitly what the number covers — reproduce,
  implement, test, run the suite, self-review, one review round — and what it
  never covers: deployment, production data fixes, client communication, and any
  work behind an unanswered `[OTVORENÉ]` question.
- **Uncertainty is now an open question, not a surcharge.** Where the old text
  told you to pad for "unknown unknowns", the new one tells you to write the
  question into the task, estimate the investigation that answers it, and state
  what the fix costs under each answer.
- **The 240-minute split threshold is now named as the working ceiling**, so it
  no longer contradicts the 480-minute hard cap sitting in the same paragraph.
- The methodology block is byte-identical across `teamwork-task-analyze`,
  `teamwork-tasks-from-dnr`, `teamwork-tasks-from-desk`,
  `teamwork-tasks-from-session` and `dnr-business`, and now carries a version
  marker so a drifted copy is visible.
- Step 6.4 now states why this plugin matters to the methodology: it is the only
  one in the family that puts an estimate and a **measured** duration next to
  each other on the same work. When they differ by more than half, the preview
  says so in one line — the anchor used and the real number. Repeated drift on
  the same kind of work is the signal to move an anchor in the methodology block,
  never to bring a buffer percentage back.

### Removed
- Config keys `estimate.buffer_pct_min`, `estimate.buffer_pct_max`,
  `estimate.speedup_pct_min` and `estimate.speedup_pct_max`. The config
  migration deletes them from files written by earlier versions and renames
  `methodology` from `wame_senior_claude_code` to `wame_estimate_v2` — a stale
  `buffer_pct_max` left in the file reads like a rule somebody still follows.

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
