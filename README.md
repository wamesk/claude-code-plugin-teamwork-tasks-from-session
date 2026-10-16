# teamwork-tasks-from-session

Turn **the work you just did in a Claude Code session** into a Teamwork
**Projects** task (plus optional subtasks) — for the very common case where you
start solving a problem in Claude Code *before* a task even exists for it.

Goal: after the session, one command turns what you actually did into a
ready-to-track task with acceptance criteria, a goal, a Plan-Mode technical
write-up, a WAME estimate — and a **real time log** for the minutes the session
actually took.

## Install

```
/plugin marketplace add wamesk/claude-code
/plugin install teamwork-tasks-from-session@wame
```

Since 1.5.0 the plugin depends on **`work-rules`**, the tracker-independent
WAME rules plugin: its `wame-time-logging` skill (rules `wame-time-logging-v1`)
decides how the session time is logged, its `wame-estimate` skill (methodology
`wame-estimate-v3`) how the task is estimated. It is declared in
`dependencies` and installed with this plugin. If it is missing, the skill
proposes no time log and stops before estimating — install it with
`/plugin install work-rules@wame`.

The **Projects** API token is shared with the rest of the Teamwork plugin
family (`teamwork-task`, `teamwork-task-test`, `teamwork-task-analyze`,
`teamwork-tasks-from-desk`, `teamwork-tasks-from-dnr`) — if any of those is
already configured this plugin uses the same token. Otherwise the skill prompts
for it on first run. The token lives in
`~/.claude/plugins/data/teamwork-task-wamesk/config.json` with `chmod 600` and
survives plugin updates.

### The SessionStart hook

This plugin ships a **SessionStart hook** (`hooks/record-session-start.sh`)
that records the wall-clock start of every Claude Code session into
`~/.claude/plugins/data/teamwork-task-wamesk/sessions/starts.tsv`. That is how
the skill knows *when the session began*, so it can propose logging time from
that moment. The hook:

- writes nothing into your session (no context injection) and always exits 0,
  so it can never disrupt startup;
- only takes effect for sessions started **after** the plugin is installed and
  Claude Code is restarted (hooks load at session start).

If there is no hook record (e.g. the very session in which you install the
plugin), the skill falls back to the end of today's last timelog, then to the
newest session transcript's first timestamp, and finally just asks you — always
as an editable proposal.

## Usage

Run it at the end of a working session, optionally with the target URL:

```
/teamwork-tasks-from-session https://<workspace>.teamwork.com/app/tasklists/9876543
```

If you omit the URL the skill asks where to file the work. You can pass:

- a **project** URL → the new main task is created in that project (the skill
  picks the tasklist, or asks when there is more than one);
- a **tasklist** URL → the new main task is created in that tasklist;
- a single **task** URL → the session work is filed as a **subtask** of that
  task.

The skill then walks you through:

1. **Session window** — proposes the start (from the hook / last timelog /
   transcript / a question) and the end (now); you confirm or edit it.
2. **Concept preview** — the main task title, full canonical-format
   description, proposed subtasks, the estimate, the assignee, and the exact
   time-log entry that will be written. Nothing is created until you approve.
3. **Clarifying questions** (max 6 per run) when the session is ambiguous.
4. **Board action** — after the task is created it asks what to do with the
   board state: leave it, move it to the done column (`Done - Local`, falling
   back to `Internal testing`, then `Testing`), or mark the task complete (the
   work is already done, after all).

### Optional flags

- `--assignee=<email>` — assignee for the main task (default: you; empty =
  unassigned)
- `--no-subtasks` — never propose subtasks; single main task only
- `--language=sk|en` — language for the description and questions (default from
  config, fallback `sk`)
- `--write-back=ask|auto|never` — gate every Teamwork write (default `ask`);
  `never` stops after the preview (full dry-run, nothing created, no time
  logged)
- `--start=<ISO|HH:MM|"NNm ago">` — override the detected session start instead
  of confirming it interactively
- `--board=ask|leave|move-done|complete` — what to do with the board after
  creation (default `ask`)
- `--log-time=true|false` — whether to write the time log at all (default
  `true`)
- `--max-questions=N` — cap for clarifying questions per run (default 6)

## What it does

1. **Detects the session window** — start from the SessionStart hook record
   (fallbacks: last timelog end → newest transcript timestamp → ask), end =
   now. Always shown as an editable proposal.
2. **Reconstructs what the session accomplished** — git commits and the
   working-tree diff made since the session start, the changed files, the repo
   shape (Laravel modular / Vue / Ionic / …), and the live conversation
   context.
3. **Resolves the target** — project / tasklist / task URL, asking when none is
   given. A task URL means "file this as a subtask of that task"; the parent's
   project is read from `.task.tasklist.meta.projectId` (v3 task objects carry no
   `projectId` key).
4. **Drafts a main task** in the canonical WAME format:
   `[preamble] → HR → ## Akceptačné kritériá → HR → ## Cieľ → HR → ## Technický popis`,
   ending with a `### Zdroj` block that records branch + commits made in the
   session. The technical section is full Plan-Mode output (files, functions,
   schema changes, step-by-step, edge cases, tests) — same shape as
   `teamwork-task-analyze`.
   Since 1.3.0 the acceptance criteria carry a `### Prierezové požiadavky`
   sub-block with the applicable cross-cutting requirements — **reachability**
   (menu entry + links from related screens for a new screen), **security**
   (authorization of new actions), **performance** (lists / exports at real data
   volume) and **ui_ux** — the same four dimensions `teamwork-task-test` checks
   at QA time. Because the session describes work already done, an item is
   stated as delivered only when the diff or the conversation proves it; the
   applicable ones the session did not cover are listed as
   *nepokryté v tejto session* and are never claimed. Every box stays `- [ ]`.
   The technical section gains a short `### Kvalita` subsection with the *how* —
   plus, when the session wrote code, a `Framework:` line recording the versions
   installed in the repo (read from `composer.lock` / `package-lock.json` /
   `package.json`, never from memory) and the version-specific idioms the diff
   actually uses, each with its `path:line`. That fifth key, `framework`, is plan
   only — never an acceptance criterion, because `teamwork-task-test` treats it as
   advisory; what the diff could do better is noted as a suggestion for a later
   refactor, never as open work.
5. **Proposes subtasks** only when the estimate exceeds 240 min and the work
   has natural cut points (BE/FE/QA/Migration/DevOps role prefixes).
6. **Estimates** via the WAME estimate methodology `wame-estimate-v3`
   (one number per task against the anchors, 15 min step, split above 240 min,
   480 min cap). The methodology is not copied into this plugin: the skill loads
   it from `work-rules:wame-estimate` before the first estimate.
7. **Asks clarifying questions** via `AskUserQuestion` (batches of 4, max 6 per
   run); folds answers into AC / Cieľ / Technický popis; preserves anything
   unresolved as `[OTVORENÉ]` markers.
8. **Previews the full concept + the exact time-log entry** and waits for
   confirmation. `--write-back=never` stops here as a dry-run.
9. **Creates the main task** (or the subtask, for a task URL) via the Projects
   REST API v3 — Python-encoded payload, `estimatedMinutes` write field,
   idempotency guard that searches by name before any retry.
10. **Creates subtasks** with `parentTaskId` and per-role assignees.
11. **Logs the real session time** back to Teamwork by the rules
    `wame-time-logging-v1` (loaded from `work-rules:wame-time-logging`) — one
    entry in whole 5-minute blocks on the 5-minute grid, written in a business
    tone with an optional `(commit: <hash>)` suffix. The minutes are measured
    from the session start, or from the end of your last entry of the day when
    that is later, and rounded to the nearest block; any work of 1 minute or
    more is at least 5 minutes, so there is never a 1–4 minute entry. The entry
    never overlaps an existing one (re-read right before the write) and never
    ends after the current 5-minute block. With 0 measured minutes, or a
    timesheet that is already full, nothing is proposed and you may enter the
    minutes by hand. Split across subtasks (optional), the blocks go by the
    subtask estimates; a subtask that gets no block is named in the largest
    entry.
12. **Asks what to do with the board** — leave / move to the done column /
    mark complete. The done column is the shared `board_workflow.done_stage`
    that `teamwork-task` also uses — `Done - Local` on the WAME board, falling
    back to `Internal testing`, then `Testing` on older boards. The move only
    ever targets a workflow that lists the task's project; with no project id
    it is skipped with a warning.
13. **Renders a final report** — what was created, the time logged, the board
    action, the run duration, and any `[OTVORENÉ]` follow-ups.

## What it does **not** do

- Never runs `git commit` / `git push` (the session already produced the
  commits; this skill only reads them)
- Never logs time without an explicit confirmation
- Never writes a time log that overlaps an existing entry
- Never proposes a time entry that is not whole 5-minute blocks — no 1–4 minute
  entries (only minutes you type yourself are written as typed)
- Never silently overwrites an estimate
- Never writes the estimate into the task title or description — it goes to the
  Teamwork `estimatedMinutes` field only (the preview and the final report show
  it, the task body does not)
- Never edits an existing task's description (it only creates tasks), so it can
  never strip inline screenshots or attachment links out of somebody else's task
- Never sends anything to a customer or to Desk
- Never moves the board or completes the task without asking (default
  `board.after_create = ask`)
- Never claims a cross-cutting requirement (menu entry, authorization, …) that
  the diff or the conversation does not prove, nor a framework version or idiom
  the lock files and the diff do not show

## Shell portability

The skill's bash snippets run in your login shell — zsh on macOS, bash
elsewhere. Since 1.3.0 `SKILL.md` carries a **Shell portability contract**
(here-strings instead of `echo "$JSON" | jq`, no `${!…}` / `${…@Q}`, no bare
globs, HTTP status checked on every Teamwork GET) so later edits do not
reintroduce the zsh failures fixed in that release. The SessionStart hook is
unaffected: `hooks.json` invokes it explicitly with `bash`, and it is bash-3.2
clean.

## Config

Stored at `~/.claude/plugins/data/teamwork-task-wamesk/config.json` (shared with
the rest of the Teamwork plugin family). This plugin adds a `session_skill.*`
namespace and reuses the family's time-logging keys (`time_rounding_minutes` —
the block, 5 —, `time_cursor_strategy`,
`include_commit_hash_in_log_description`, `is_billable_by_default`). Since 1.5.0
it no longer adds `round_threshold_minutes` / `min_log_minutes`: the rules log
whole blocks only and ignore both, and they are left untouched in an older
shared file. See
`config.example.json` for the full list — section labels, estimate methodology
parameters, subtask split thresholds, role prefixes, clarifying-question cap,
session-start detection order, time-log behaviour, and board defaults.

### Board columns *(1.3.0)*

The done column comes from the **shared** `board_workflow` block, the same one
`teamwork-task` moves cards with:

| Key | Default | Meaning |
| --- | --- | --- |
| `board_workflow.done_stage` | `Done - Local` | The end column of the WAME board (Teamwork workflow "WAME workflow"). |
| `board_workflow.done_stage_fallbacks` | `["Internal testing", "Testing"]` | Tried in order when the project's board has no `done_stage` column, so an older board keeps landing where it did. |
| `board_workflow.match_mode` | `case_insensitive` | How column names are compared. |

When this plugin runs, it adds the block if it is missing and applies the same
one-time rule as `teamwork-task` 1.5.0: a `done_stage` still at the old default
`Internal testing` becomes `Done - Local`, and `Internal testing` becomes the
first fallback. A customised `done_stage` is never touched. For example, the
shape `"done_stage": "Internal testing", "done_stage_fallbacks": ["Done - Local",
"Testing"]` ends as `"Done - Local"` + `["Internal testing", "Testing"]`.
`board_workflow.done_stage_schema` records that the rule ran, so if you pick
`Internal testing` again later, it stays.

Up to 1.2.0 the plugin kept its own copies of these keys under
`session_skill.board`. Copies that still hold the old defaults are removed once
(marker `session_skill.board.stages_schema`). A customised
`session_skill.board.done_stage` stays and overrides the shared column for this
plugin only.

The shared config survives plugin updates. Tokens are `chmod 600`.

## License

MIT — © 2026 Stanislav Červeňák
