# Changelog

All notable changes to the `teamwork-tasks-from-session` plugin are documented
in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0] — 2026-09-24

Source: reported in a colleague's "Štyri cesty k nule" analysis, which traced a
family of *silent* failures in the Teamwork plugins to v3 fields that do not exist
and to bash-only snippets running under zsh. This plugin had its own instances of
both.

### Fixed
- **No task could be created from zsh or macOS bash 3.2.** Steps 11 and 12 spliced
  `${PRIMARY_NAME@Q}`, `${SUB_NAME@Q}` and `${SUB_RESP@Q}` into Python source. `@Q`
  is bash 4.4+ only: zsh (what Claude Code's Bash tool runs on macOS) and the
  stock `/bin/bash` 3.2 both answer `bad substitution`, so the `python3` heredoc
  never ran, the POST went out with an empty payload file, and the idempotency
  probe failed the same way — the run ended in "Primary task creation failed".
  On bash 4.4+ it ran, but shell quoting is not Python quoting, so a crafted task
  name could break out of the string. Name and description now travel through
  temp files, the subtask response through stdin — the pattern
  `teamwork-tasks-from-desk` adopted in 1.0.2.
  Repro: `zsh -c 'N=x; python3 - <<PY
print(${N@Q})
PY'` → `zsh:1: bad substitution`.
- **Subtask mode lost the project, and the board move could target a stranger's
  board.** Step 5.4 read `PROJECT_ID` from `.task.projectId`; v3 task objects have
  no such key, so it was always empty. Step 14.1 then asked
  `workflows.json?projectIds=` — which is not an error: it answers HTTP 200 with the
  first 50 workflows of the whole workspace, none of them this project's, and their
  pooled stages include `Testing`. `.workflows[0]` was therefore another project's
  workflow. Now `PROJECT_ID` comes from `.task.projectId // .task.tasklist.meta.projectId
  // included.tasklists[].projectId`, the move is skipped with a warning when it is
  still empty, only a workflow whose `projectIds` lists the project is used, and
  stage names are resolved among that workflow's own stages only.
  Repro (read-only): `GET /projects/api/v3/tasks/45198800.json?include=tasklists,projects`
  → `.task.projectId` = `null`, new expression = `700336`;
  `GET /projects/api/v3/workflows.json?projectIds=&include=stages` → 200, 50
  workflows, first one `8105 "1Plus1 - 634056"`.
- **The project name was always blank for tasklist and task URLs.** `.tasklist.project`
  is only an `{id, type}` reference, so `.tasklist.project.name` never existed. The
  tasklist lookup now asks `?include=projects` and reads
  `.included.projects["<id>"].name`; subtask mode also fills `TASKLIST_NAME` from
  `.task.tasklist.meta.name`. The Step 10 preview shows both again.
  Repro: `GET /projects/api/v3/tasklists/3361804.json` → `.tasklist.project` =
  `{"id":700336,"type":"projects"}`.
- **The overlap clamp had no anchor when the SessionStart hook won.** Step 3.2 read
  today's last timelog only when no hook record existed, yet Step 9 clamps against
  its end. The read now runs whenever the user is known, so a session that began
  before the last logged block ended is clamped instead of billed twice.
- **Failed reads looked like empty results.** `me.json`, `time.json`, the target
  lookups and `people.json` did not check the HTTP status, so a 401/404/400 body was
  parsed as "no user / no timelog / no match". Every GET now captures the status and
  prints a `⚠` line naming the endpoint and the fallback; target lookups stop.
- **"Mark complete" reported success it did not have.** Step 14.2 ran
  `curl … >/dev/null && BOARD_RESULT="completed"`; curl exits 0 on an HTTP error, so
  a 401 / 403 / 404 was reported as "completed". It now judges the status code and
  reports `complete failed (HTTP <code>)` with the response body.
- **The transcript fallback aborted in zsh when no transcript existed** —
  `ls -t "$PROJ_DIR"/*.jsonl` is a `no matches found` error before `2>/dev/null`
  applies. Replaced with `find`.
- **A `false` in the config flipped back to `true` on every run.** Step 2.5
  defaulted every boolean with `//=`, and jq's `//` treats `false` like a missing
  value. So `is_billable_by_default: false` and
  `include_commit_hash_in_log_description: false` — keys `teamwork-task` owns in
  the same shared file — became `true` whenever this plugin ran, and the session
  time went out billable. The plugin's own switches (`time_log.enabled`,
  `assignee.ask`, `session_start.hook_enabled`, …) could not be turned off
  either. Booleans now default only when absent (`null`), and the Step 3, 9, 13
  and 15 reads no longer use `// true`.
  Repro: `jq -n '{is_billable_by_default: false} | .is_billable_by_default //= true'`
  → `{"is_billable_by_default": true}`.
- The assignee email was spliced into the jq program text; it is now a `--arg`.
- `LANG` was overwritten with the description language (`sk`), handing every later
  command in that shell an invalid locale. Renamed to `DESC_LANG`.

### Added
- **Cross-cutting requirements in the drafted task** (Step 6.2a). The acceptance
  criteria gain a `### Prierezové požiadavky` sub-block with the dimensions that
  apply — `reachability` (a new screen is reachable from the menu and from the
  related screens), `security` (new actions behind the same gate plus an
  object-scoped check), `performance` (lists and exports at real data volume) and
  `ui_ux` — named with the same keys `teamwork-task-test` 1.1.0 uses at QA time.
  Because this skill describes work that is already done, an item is stated as
  delivered only when the diff or the conversation proves it (with the evidence
  cited); applicable items the session did not cover are listed as
  *nepokryté v tejto session*, never claimed, and surfaced in the preview and the
  board question. Every box stays `- [ ]`; the sub-block sits before the first `---`
  so `teamwork-task-test` can tick it. The technical section gains a short
  `### Kvalita` subsection. Questions about these count against the existing max-6
  budget.
- **Framework versions and idioms in the technical plan** (Step 6.2b, key
  `framework`). Step 4.2 now also reads the installed versions with a zsh/bash-safe
  snippet, in the nearest directory up to the git root that holds a manifest (the
  app may sit in a subdirectory of the repo). It reads `composer.json`
  (`config.platform.php` / `require.php`), `composer.lock` (Laravel, Nova, Livewire,
  Inertia, Pest), `package-lock.json` (lockfile v1–v3) or the declared range in
  `package.json` (Vue, Nuxt, React, Ionic, Inertia, Tailwind CSS, Vite, TypeScript),
  `browserslist` and `.nvmrc`. The `### Kvalita` subsection then gets one
  `Framework:` line recording what the session **actually used**: those versions
  plus the version-specific idioms the diff shows, each cited by `path:line`. Why:
  the other plugins now build in the installed version's idioms and
  `teamwork-task-test` reviews them, so the record of a session should say which
  ones it used — and never claim one it did not. Whether something is deprecated
  or newer than installed is checked in current docs (Boost `search-docs`,
  context7, official docs), not from memory. What the diff could do better is a
  "suggestion for a later refactor", never open work or part of the estimate; a
  feature newer than the installed version goes under *Edge cases & risks*
  because it will not run. Plan only — **never** an acceptance criterion or a
  `Prierezové požiadavky` item: `teamwork-task-test` treats `framework` as
  advisory, so such a box could never be ticked. The subsection heading is
  `### Kvalita (UI/UX, výkon, bezpečnosť, dostupnosť, framework)` (en `### Quality
  (UI/UX, performance, security, reachability, framework)`) — the same label
  `teamwork-task-analyze` 1.3.0 uses.
- **Shell portability contract** near the top of `SKILL.md`: the rules above in
  eight bullets, so later edits do not reintroduce them.

### Changed
- **The board move lands in `Done - Local` on the new WAME board.** The shared
  board (Teamwork workflow "WAME workflow", ~49 projects) ends work in *Done -
  Local*, and it has no *Internal testing* column. The end-of-run option
  "move In progress → Internal testing" read the plugin's own
  `session_skill.board.done_stage` (`Internal testing`) with the fallback
  `Testing`. On the new board neither column exists, so the move was skipped
  with "no 'Internal testing' (or fallback) stage". Step 14 now uses the
  **shared** `board_workflow.done_stage` + `done_stage_fallbacks` +
  `match_mode`, the keys `teamwork-task` moves cards with. The defaults are
  `Done - Local`, then `Internal testing`, then `Testing`, so an older
  per-project board keeps landing where it did.
  - The question, the preview and the `--board=move-done` help name the
    configured chain instead of a hard-coded "Internal testing".
  - `match_mode` is honoured: `case_sensitive` compares exactly. Both sides of
    the case-insensitive compare go through jq's `ascii_downcase`, so the needle
    and the table can no longer disagree.
  - Verified read-only: project 736882 and project 589836 (both "WAME workflow"
    59165) resolve to *Done - Local* 301170. Project 700336 (workflow 58171, no
    *Done - Local* and no *Internal testing*) falls back to *Testing* 295928. An
    empty project id still skips the move.
- **Config migration for the shared keys, the same rule as `teamwork-task`
  1.5.0.** Both plugins write one file, so neither may undo what the other did.
  Step 2.5 adds `board_workflow` when it is missing. It moves `done_stage` to
  `Done - Local` **only** when it still holds the old default `Internal
  testing` and `board_workflow.done_stage_schema` is absent. `Internal testing`
  then becomes the first fallback, followed by the existing fallbacks minus
  `Done - Local`, deduplicated case-insensitively. A customised `done_stage`
  is never touched. The marker is then set to `2`, so a later deliberate
  `Internal testing` sticks.
  - For the user's live config (`done_stage: "Internal testing"`,
    `done_stage_fallbacks: ["Done - Local", "Testing"]`), the result is
    `done_stage: "Done - Local"`, `done_stage_fallbacks: ["Internal testing",
    "Testing"]`.
  - The plugin's own copies `session_skill.board.in_progress_stage` /
    `done_stage` / `done_stage_fallbacks` / `match_mode` are removed once while
    they still hold the old defaults (marker `session_skill.board.stages_schema:
    2`). A customised `session_skill.board.done_stage` stays, with its own
    fallbacks, as an override for this plugin only.
  - Verified on token-stripped scratch copies of the live shape, a fresh file,
    a customised file and the old default, in zsh and bash: every run is
    idempotent, and running `teamwork-task`, `teamwork-task-analyze` and this
    plugin in any order leaves the same settings (only the key order differs).
    A customised config keeps its values, a boolean `false` included.
    `config.example.json` gains the shared `board_workflow` block and loses
    the stage copies.

Deliberately not changed: `hooks/record-session-start.sh` — `hooks.json` runs it
explicitly with `bash` (shebang `#!/usr/bin/env bash`) and it is bash-3.2 clean, so
zsh never executes it. The estimate-never-in-the-description rule, the preview +
confirmation gate, the timelog cursor rules and the TIMEZONE CONTRACT are intact.

## [1.2.0] — 2026-09-22

### Changed
- **Two new rules, shared verbatim as the `wame-task-record-v1` block.**
  1. *The estimate lives in the estimate field, and nowhere else.* Minutes never go
     into a task title or description — not in the preamble, not in the technical
     plan, not as a footer line. An estimate gets revised, and a number duplicated
     into prose has to be changed in every copy; the copy somebody misses is the one
     the next reader believes. Previews, confirmation gates, final reports and
     companion documents may still show it — those are read once and thrown away.
  2. *Never lose what the reporter wrote.* When an existing description is rewritten,
     everything already there survives verbatim at the top: inline images, links, the
     reporter's own wording, spelling and punctuation. No diacritics added, no grammar
     fixed, no translation, no tidying.
- Step 6.2's description template, Step 6.3's subtask sentence and the Hard boundaries
  list now say where the estimate goes. The plugin had no violation — it writes the
  number only to `estimatedMinutes` — but nothing forbade one, and the Step 10 preview
  renders `**Odhad (metodika):** <EST> min`, which is the prose shape that bleeds into a
  free-form preamble.
- The Hard boundaries list gained the preservation rule. The plugin only ever POSTs new
  tasks today, so nothing is at risk — but the obvious next feature for subtask mode,
  linking the new subtask from the parent description, is exactly the edit that strips
  inline images.

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
