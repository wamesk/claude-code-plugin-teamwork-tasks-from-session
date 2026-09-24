---
name: teamwork-tasks-from-session
description: "Use when the user has been solving something directly in a Claude Code session (often before any task existed) and asks to 'vytvor task z tejto session', 'vytvor teamwork task zo session', 'zaloguj túto session ako task', 'sprav task z toho čo sme robili', 'z tejto session vytvor task a zaloguj čas', 'create a task from this session', 'log this session as a task', or invokes '/teamwork-tasks-from-session'. Reconstructs what the session accomplished — git commits + working-tree diff made since the session started, changed files, repo shape, and the live conversation context — and drafts a Teamwork.com Projects task in the canonical WAME format ([preamble] → HR → Akceptačné kritériá → HR → Cieľ → HR → Technický popis, the same Plan-Mode technical write-up produced by teamwork-task-analyze), with optional 2–6 atomic subtasks and a `wame-estimate-v2` estimate shown next to the real logged session time. Detects the session start from a bundled SessionStart hook (fallbacks: end of today's last timelog → newest session transcript timestamp → ask) and logs the real session duration back to Teamwork as one sequential, non-overlapping, 5-minute-aligned entry — always shown as an editable proposal first, clamped so it never overlaps an existing timelog. If no Teamwork URL is passed it asks where to file the work; a project/tasklist URL creates a new main task, a single-task URL files the work as a subtask of that task. Asks via AskUserQuestion which Teamwork email to assign the task to (you by default, unassigned, or a custom email resolved via people.json). Everything is shown in a full preview + confirmation gate before any write; after creation the skill asks what to do with the board (leave / move to the done column — Done - Local, fallbacks Internal testing → Testing, the shared board_workflow target teamwork-task uses / complete). Reuses the shared API token config with the rest of the Teamwork plugin family. Never runs git, never logs time without confirmation, never writes an overlapping time log, never silently overwrites an estimate."
argument-hint: "[<projects-or-tasklist-or-task-url>] [--assignee=<email>] [--no-subtasks] [--language=sk|en] [--write-back=ask|auto|never] [--start=<ISO|HH:MM|\"NNm ago\">] [--board=ask|leave|move-done|complete] [--log-time=true|false] [--max-questions=N]"
allowed-tools: [Bash, Read, Write, Edit, Grep, Glob, AskUserQuestion]
---

# Teamwork Tasks From Session

Turn **the work you just did in this Claude Code session** into a Teamwork
**Projects** task (plus optional subtasks) — for the common case where you
start solving a problem in Claude Code *before* a task exists for it. The skill
reconstructs what the session accomplished, drafts a task in the canonical WAME
format, computes an estimate, and **logs the real session time** back to
Teamwork.

The user invoked this skill with: `$ARGUMENTS`

This skill is the **inverse** of `teamwork-task`: instead of "pull a task and
implement it", it is "I already implemented something — now create and bill the
task for it". It is read-only against git (it only *reads* the commits the
session produced — it never commits, never pushes) and writes to Teamwork only:

1. POSTing the main task + confirmed subtasks (or a subtask of a given task)
2. One time-log entry for the real session duration (after explicit confirmation)
3. (Optionally, asked per run) a board move or a task-complete flag

Everything else — the estimate, the description, the time window — is shown as
an editable proposal and gated behind a confirmation.

---

## Shell portability contract

Every bash snippet below runs in the user's login shell: **zsh on macOS** (that is
what Claude Code's Bash tool starts there), bash elsewhere. Each Bash tool call is
a **fresh shell** — variables and functions do not survive into the next call.
Future edits must keep these rules, because every one of them has already failed
silently somewhere in the Teamwork plugin family:

- **JSON goes to `jq` on stdin via a here-string** — `jq … <<<"$JSON"` or
  `printf '%s\n' "$JSON" | jq …`. Never `echo "$JSON" | jq`: zsh's `echo` expands
  `\n`, `\t`, `\\` inside the JSON and jq rejects the whole response.
- **Line lists are read with `while IFS= read -r X; do …; done <<<"$LIST"`.** An
  unquoted `for X in $LIST` iterates exactly once in zsh (no word splitting).
- **No bash-only expansions:** `${!ARR[@]}`, `${!name}`, `${X@Q}`, `${X,,}` all
  answer `bad substitution` in zsh (and the last two in macOS bash 3.2). zsh arrays
  are 1-based — read an element with the slice `${ARR[@]:$i:1}`, never `${ARR[$i]}`.
- **`[ "$a" = "$b" ]`** — a single `=`; `==` inside `[ ]` fails in zsh.
- **No bare globs that may not match** (`ls "$DIR"/*.jsonl` aborts with
  `no matches found` in zsh) — use `find`. Quote every URL (they contain `?` and
  `&`) and every word that starts with `=`.
- **Every Teamwork GET checks its HTTP status** (`-w '\n%{http_code}'`). A failed
  call or parse prints a `⚠` line naming the endpoint and the fallback the run
  takes — never `2>/dev/null || echo 0`, which turns an error into "nothing there".
- **A function is defined in the same Bash call that uses it** (`parse_iso`,
  `lookup_stage`). Untrusted text — task names, API responses — reaches Python
  through a temp file, argv or stdin, never spliced into Python source.
- **Never assign to `LANG` / `LC_*`** — they are the shell's locale. The
  description language lives in `DESC_LANG`.

---

## Arguments

Expected (optional) first positional argument: a Teamwork.com URL telling the
skill **where** to file the work. Recognised shapes (same parser as the rest of
the family):

- Project:  `https://<workspace>.teamwork.com/app/projects/<projectId>`
- Tasklist: `https://<workspace>.teamwork.com/app/tasklists/<tasklistId>` (also legacy `/tasklists/<id>`)
- Task:     `https://<workspace>.teamwork.com/app/tasks/<taskId>` (also `/#/tasks/<id>`, `/tasks/<id>`)

If no URL is passed, the skill asks for one in **Step 5**.

Optional flags (override config for this run only — not persisted):

- `--assignee=<email>` — assignee for the main task; skips the Step 7 question.
  Empty string = unassigned.
- `--no-subtasks` — never propose subtasks; create a single main task only.
- `--language=sk|en` — language for the description and the questions (default
  from config, fallback `sk`).
- `--write-back=ask|auto|never` — gate every Teamwork write (default `ask`).
  `auto` skips the Step 10 confirmation; `never` stops after the preview (full
  dry-run — nothing created, no time logged).
- `--start=<ISO|HH:MM|"NNm ago">` — override the detected session start instead
  of confirming it interactively (Step 3). Accepts an ISO-8601 timestamp, a
  `HH:MM` time today, or a relative `"45m ago"` / `"2h ago"`.
- `--board=ask|leave|move-done|complete` — what to do with the board after the
  task is created (default `ask`). `leave` = no change; `move-done` = move to
  the done column (shared `board_workflow.done_stage`, default `Done - Local`,
  fallbacks `Internal testing` → `Testing`); `complete` = mark the task complete.
- `--log-time=true|false` — whether to write the time log at all (default
  `true`). `false` creates the task without billing any time.
- `--max-questions=N` — cap for clarifying questions per run (default 6).

---

## Step 1 — Parse the target URL (if any) + record run start

```bash
ARGS="$ARGUMENTS"
URL=$(printf '%s' "$ARGS" | grep -oE 'https?://[^ ]+teamwork\.com[^ ]*' | head -1)

WORKSPACE=""; ENTITY_ID=""; URL_KIND=""
if [ -n "$URL" ]; then
  WORKSPACE=$(printf '%s' "$URL" | sed -nE 's|https?://([^.]+)\.teamwork\.com/.*|\1|p')
  ENTITY_ID=$(printf '%s' "$URL" | sed -nE 's|.*/(projects|tasklists|tasks)/([0-9]+).*|\2|p')
  URL_KIND=$(printf '%s'  "$URL" | sed -nE 's|.*/(projects|tasklists|tasks)/[0-9]+.*|\1|p' | sed 's/s$//')
fi
```

Capture a start timestamp **before any network I/O** so the Step 15 report can
show how long the hand-off took (this is the run duration of *the skill*, not
the session being logged):

```bash
RUN_START_EPOCH=$(date -u +%s)
RUN_START_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
```

If a URL was given but `WORKSPACE` or `ENTITY_ID` is empty, treat it as "no
valid URL" and fall through to the Step 5 question rather than guessing.

---

## Step 2 — Load shared config (Teamwork plugin family)

This skill deliberately shares the config file with the `teamwork-task`,
`teamwork-task-test`, `teamwork-task-analyze`, `teamwork-tasks-from-desk` and
`teamwork-tasks-from-dnr` plugins, so a user who configured any of those has
nothing extra to enter.

```
~/.claude/plugins/data/teamwork-task-wamesk/config.json
```

Algorithm:

1. `CONFIG_DIR="$HOME/.claude/plugins/data/teamwork-task-wamesk"` — `mkdir -p "$CONFIG_DIR"`.
2. `CONFIG_FILE="$CONFIG_DIR/config.json"`.
3. If `CONFIG_FILE` does not exist, copy this plugin's bundled template from
   `${CLAUDE_PLUGIN_ROOT}/config.example.json` and `chmod 600 "$CONFIG_FILE"`.
4. Validate with `jq . "$CONFIG_FILE" >/dev/null`. If invalid → report and stop.
5. **First-run check** — two keys must be set:
   - `.teamwork.base_url` — workspace base URL (prefill from the parsed URL when
     present, otherwise ask).
   - `.teamwork.api_token` — Projects API token (shared with the family); get
     from `https://<workspace>.teamwork.com/launchpad/apikey/manage`.

   If either is missing/empty/placeholder, prompt via **AskUserQuestion**, write
   back atomically with `jq` + `mv`, then `chmod 600`.
6. **Apply this skill's config defaults** — see Step 2.5.
7. **Apply CLI flag overrides** to the in-memory config — do not persist.
8. **Never echo the token.** Always pass auth via `-u "$AUTH"` (kept out of
   `ps`), never in a URL.

```bash
TOKEN=$(jq -r '.teamwork.api_token' "$CONFIG_FILE")
BASE=$(jq  -r '.teamwork.base_url'  "$CONFIG_FILE")
AUTH="${TOKEN}:xxx"
```

### Step 2.5 — Session-skill config defaults (idempotent merge)

Add this skill's own keys to the shared config, defaulting any missing key. Run
on every invocation — it is idempotent and never clobbers a user's value:
strings, numbers and objects default with `//=`, booleans with `null_or()`,
because `//=` would also replace a deliberate `false`.

```bash
TMP=$(mktemp)
jq '
  # `//=` replaces `false` as well as `null`, so a boolean default written with
  # it flipped a deliberate `false` back to `true` on every run — including the
  # shared `is_billable_by_default` / `include_commit_hash_in_log_description`
  # that teamwork-task owns. Booleans are defaulted with null_or() instead.
  def null_or($d): if . == null then $d else . end;
  .default_language                                   //= "sk"
| .time_rounding_minutes                              //= 5
| .round_threshold_minutes                            //= 4
| .min_log_minutes                                    //= 1
| .time_cursor_strategy                               //= "last_teamwork_timelog"
| .include_commit_hash_in_log_description             |= null_or(true)
| .is_billable_by_default                             |= null_or(true)
| .session_skill                                      //= {}
| .session_skill.write_back_mode                      //= "ask_each"
| .session_skill.description_format                   //= "wame_canonical"
| .session_skill.sections                             //= {}
| .session_skill.sections.preamble_label              //= ""
| .session_skill.sections.acceptance_label_sk         //= "Akceptačné kritériá"
| .session_skill.sections.acceptance_label_en         //= "Acceptance criteria"
| .session_skill.sections.goal_label_sk               //= "Cieľ"
| .session_skill.sections.goal_label_en               //= "Goal"
| .session_skill.sections.tech_label_sk               //= "Technický popis"
| .session_skill.sections.tech_label_en               //= "Technical plan"
| .session_skill.sections.source_label_sk             //= "Zdroj"
| .session_skill.sections.source_label_en             //= "Source"
| .session_skill.sections.hr_marker                   //= "---"
| .session_skill.estimate                             //= {}
| .session_skill.estimate.methodology                 //= "wame_estimate_v2"
| .session_skill.estimate.set_if_missing              |= null_or(true)
| .session_skill.estimate.step_minutes                //= 15
| .session_skill.estimate.max_task_minutes            //= 480
# v2 estimates one number directly — the speedup/buffer multipliers are gone.
# Delete them from configs written by 1.0.x so a stale `buffer_pct_max` does
# not sit in the file reading like a rule somebody still follows.
| .session_skill.estimate |= del(.buffer_pct_min, .buffer_pct_max,
                                 .speedup_pct_min, .speedup_pct_max)
| (if .session_skill.estimate.methodology == "wame_senior_claude_code"
   then .session_skill.estimate.methodology = "wame_estimate_v2" else . end)
| .session_skill.subtasks                             //= {}
| .session_skill.subtasks.enabled                     |= null_or(true)
| .session_skill.subtasks.propose_split_threshold_minutes //= 240
| .session_skill.subtasks.min_split_subtasks          //= 2
| .session_skill.subtasks.max_split_subtasks          //= 6
| .session_skill.subtasks.role_prefixes               //= ["BE","FE","QA","Migration","DevOps"]
| .session_skill.assignee                             //= {}
| .session_skill.assignee.default_to_me               |= null_or(true)
| .session_skill.assignee.ask                         |= null_or(true)
| .session_skill.assignee.allow_empty                 |= null_or(true)
| .session_skill.clarifying_questions                 //= {}
| .session_skill.clarifying_questions.max_per_run     //= 6
| .session_skill.clarifying_questions.fold_into_description |= null_or(true)
| .session_skill.clarifying_questions.leave_unresolved_as_open_marker //= "[OTVORENÉ]"
| .session_skill.session_start                        //= {}
| .session_skill.session_start.detection_order        //= ["hook","last_timelog","transcript","ask"]
| .session_skill.session_start.hook_enabled           |= null_or(true)
| .session_skill.session_start.sessions_log_relpath   //= "sessions/starts.tsv"
| .session_skill.session_start.constrain_today        |= null_or(true)
| .session_skill.session_start.ignore_sources         //= ["compact"]
| .session_skill.session_start.max_session_hours_warn //= 6
| .session_skill.time_log                             //= {}
| .session_skill.time_log.enabled                     |= null_or(true)
| .session_skill.time_log.log_target                  //= "primary_task"
| .session_skill.time_log.avoid_overlap               |= null_or(true)
| .session_skill.time_log.confirm_before_log          |= null_or(true)
| .session_skill.board                                //= {}
| .session_skill.board.after_create                   //= "ask"
# 1.3.0: the done column comes from the SHARED `board_workflow` below. Up to
# 1.2.0 this skill kept its own copies of the stage keys; each copy that still
# holds its old default is dropped ONCE (marker `stages_schema: 2`), so the
# shared key rules. A customised done stage stays as a skill-only override,
# together with its own fallbacks.
| (if (.session_skill.board.stages_schema // 1) < 2 then
     (if .session_skill.board.done_stage == "Internal testing"
      then del(.session_skill.board.done_stage) else . end)
   | (if .session_skill.board.done_stage == null
         and .session_skill.board.done_stage_fallbacks == ["Testing"]
      then del(.session_skill.board.done_stage_fallbacks) else . end)
   | (if .session_skill.board.in_progress_stage == "In progress"
      then del(.session_skill.board.in_progress_stage) else . end)
   | (if .session_skill.board.match_mode == "case_insensitive"
      then del(.session_skill.board.match_mode) else . end)
   | .session_skill.board.stages_schema = 2
   else . end)
# Shared `board_workflow` (owned by teamwork-task) — EXACTLY its 1.5.0 Step 2.6
# rule, so the file ends in the same state whichever plugin runs first: add
# the block when missing; move `done_stage` to "Done - Local" ONLY when it is
# still the old default "Internal testing" and the marker says this never ran
# ("Internal testing" becomes the first fallback, the existing fallbacks
# follow minus "Done - Local", deduplicated case-insensitively); a customised
# done stage is never touched. The marker makes a later deliberate
# "Internal testing" stick.
| (.board_workflow //= {
    "enabled": true,
    "in_progress_stage": "In progress",
    "done_stage": "Done - Local",
    "done_stage_fallbacks": ["Internal testing", "Testing"],
    "match_mode": "case_insensitive",
    "done_stage_schema": 2
  })
| (if (.board_workflow | type) == "object"
      and (.board_workflow.done_stage_schema // 1) < 2
      and .board_workflow.done_stage == "Internal testing"
   then .board_workflow.done_stage = "Done - Local"
        | .board_workflow.done_stage_fallbacks =
            (["Internal testing"]
             + [ (.board_workflow.done_stage_fallbacks
                   | if type == "array" then .[] elif type == "string" then . else empty end)
                 | select(type == "string" and length > 0)
                 | select(ascii_downcase as $n | $n != "done - local" and $n != "internal testing") ]
             | reduce .[] as $s ([];
                 if any(.[]; ascii_downcase == ($s | ascii_downcase)) then . else . + [$s] end))
   else . end)
| (if (.board_workflow | type) == "object" and (.board_workflow.done_stage_schema // 1) < 2
   then .board_workflow.done_stage_schema = 2
   else . end)
| .session_skill.link_session                         //= {}
| .session_skill.link_session.include_commits         |= null_or(true)
| .session_skill.link_session.include_branch          |= null_or(true)
| .session_skill.link_session.max_commits_listed      //= 20
| .session_skill.task_create_estimate_field           //= "estimatedMinutes"
| .session_skill.timing                               //= {}
| .session_skill.timing.report_run_duration           |= null_or(true)
| .session_skill.timing.duration_format               //= "human"
' "$CONFIG_FILE" > "$TMP" && mv "$TMP" "$CONFIG_FILE" && chmod 600 "$CONFIG_FILE"
```

CLI flags override `.session_skill.*` and the time keys for the duration of this
run only.

**Shared board keys (1.3.0).** The Step 14 board move uses the same
`board_workflow.done_stage` + `done_stage_fallbacks` + `match_mode` as
`teamwork-task`, which owns them. This merge only **adds** the block when it is
missing and applies exactly `teamwork-task` 1.5.0's one-time old-default rule —
it never rewrites a value the user chose. Examples:
- The user's live shape `{"done_stage": "Internal testing",
  "done_stage_fallbacks": ["Done - Local", "Testing"]}` → `"Done - Local"` +
  `["Internal testing", "Testing"]`.
- The old default (`"Internal testing"` + `["Testing"]`) → the same result.
- A fresh file → the new default block.
- A customised `"QA"` → stays `"QA"`.

This skill's own `session_skill.board.done_stage` / `done_stage_fallbacks` /
`match_mode` (up to 1.2.0 copies of the old defaults) are dropped once when
they still hold those defaults. A customised value stays and overrides the
shared key for this skill only.

Resolve the language once:

```bash
# Not `LANG` — that is the shell's locale variable, and overwriting it with "sk"
# hands every later jq/python3/sort in this shell an invalid locale.
DESC_LANG=$(jq -r '.default_language // "sk"' "$CONFIG_FILE")   # CLI --language wins
ACC_LABEL=$(jq -r --arg l "$DESC_LANG" '.session_skill.sections["acceptance_label_"+$l] // .session_skill.sections.acceptance_label_sk' "$CONFIG_FILE")
GOAL_LABEL=$(jq -r --arg l "$DESC_LANG" '.session_skill.sections["goal_label_"+$l]       // .session_skill.sections.goal_label_sk' "$CONFIG_FILE")
TECH_LABEL=$(jq -r --arg l "$DESC_LANG" '.session_skill.sections["tech_label_"+$l]       // .session_skill.sections.tech_label_sk' "$CONFIG_FILE")
SRC_LABEL=$(jq -r --arg l "$DESC_LANG" '.session_skill.sections["source_label_"+$l]      // .session_skill.sections.source_label_sk' "$CONFIG_FILE")
```

### Step 2.6 — Resolve the current user (cached for the whole run)

Needed both for the "last timelog" session-start fallback (Step 3) and for the
"assign to me" default (Step 7).

```bash
RESP=$(curl -sS -u "$AUTH" -H "Accept: application/json" -w '\n%{http_code}' "${BASE}/me.json")
HTTP=${RESP##*$'\n'}; ME_JSON=${RESP%$'\n'*}
if [ "$HTTP" != "200" ]; then
  echo "⚠ GET /me.json → HTTP $HTTP — no current user: 'assign to me' and the last-timelog start are unavailable this run" >&2
  ME_JSON='{}'
fi
USER_ID=$(   jq -r '.person.id           // empty' <<<"$ME_JSON")
MY_EMAIL=$(  jq -r '.person.emailAddress  // .person.email // empty' <<<"$ME_JSON")
MY_NAME=$(   jq -r '((.person.firstName // "") + " " + (.person.lastName // "")) | gsub("^ +| +$";"")' <<<"$ME_JSON")
```

If `USER_ID` cannot be resolved (HTTP 401 → re-prompt the token; other → warn),
the last-timelog fallback and the "assign to me" default degrade gracefully —
the skill still works, it just asks more.

---

## Step 3 — Determine the session window (start → now)

This is the step that makes the skill possible: **how long did this session
take, and from when?** The end of the window is always *now*; the start is
detected in the configured `session_skill.session_start.detection_order`
(default `hook → last_timelog → transcript → ask`). Whatever is found is shown
to the user as an **editable proposal** — never silently trusted.

```bash
NOW_EPOCH=$(date +%s)
TODAY=$(date +%Y-%m-%d)
PWD_NOW=$(pwd -P 2>/dev/null || pwd)
CONSTRAIN_TODAY=$(jq -r '.session_skill.session_start.constrain_today | if . == null then true else . end' "$CONFIG_FILE")
SESS_TSV="${CONFIG_DIR}/$(jq -r '.session_skill.session_start.sessions_log_relpath // "sessions/starts.tsv"' "$CONFIG_FILE")"

START_EPOCH=""
START_SOURCE=""
```

A cross-platform ISO-8601 → epoch parser (identical to the one in
`teamwork-task` Step 5.5), used by several branches below. Tool calls do not
share functions: paste this definition at the top of **every** Bash call that
calls `parse_iso` (Steps 3.0, 3.2, 3.3) — a call to a function defined in an
earlier call fails with `command not found`, and the empty result would read as
"no start detected".

```bash
# TIMEZONE CONTRACT (critical): Teamwork RETURNS `timeLogged` in UTC (`Z`), so it
# must be parsed AS UTC — `date -ju` (the `-u` is mandatory; the `Z` in the BSD
# format is a literal, NOT a zone directive, so without `-u` BSD `date` reads the
# wall-clock as LOCAL and the epoch is wrong by the local offset). The POST/PATCH
# `time` field, however, is interpreted by Teamwork in the user's LOCAL/profile
# timezone — so the absolute epoch is later formatted for the POST with LOCAL
# `date -r` (Step 6.x), NEVER `date -ju`/`date -u`. Parse UTC, post local.
# A no-`Z` local input (e.g. a `--start 2026-06-10T08:30:00` value) does not match
# the `Z` branch and falls through to GNU `date -d` / Python, which treat a naive
# timestamp as local — so adding `-u` here only affects genuine UTC inputs.
parse_iso() {
  local raw norm out
  raw="$1"
  norm=$(printf '%s' "$raw" | sed -E 's/\.[0-9]+(Z|[+-][0-9:]{2,5})?$/\1/' | sed -E 's/[+-]00:?00$/Z/')
  out=$(date -ju -f "%Y-%m-%dT%H:%M:%SZ" "$norm" +%s 2>/dev/null)  && { [ -n "$out" ] && echo "$out" && return 0; }
  out=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$raw"  +%s 2>/dev/null) && { [ -n "$out" ] && echo "$out" && return 0; }
  out=$(date -d "$raw" +%s 2>/dev/null)                          && { [ -n "$out" ] && echo "$out" && return 0; }
  out=$(python3 - "$raw" <<'PY' 2>/dev/null
import sys, datetime
s = sys.argv[1].replace('Z', '+00:00')
try: print(int(datetime.datetime.fromisoformat(s).timestamp()))
except Exception: pass
PY
)
  [ -n "$out" ] && echo "$out" && return 0
  echo ""
}
```

### Step 3.0 — `--start` override

If the `--start` flag was passed, parse it and **skip detection entirely**:

- ISO-8601 (`2026-06-10T08:30:00`) → `parse_iso`
- `HH:MM` → today at that local time
- `"NNm ago"` / `"NNh ago"` → `NOW_EPOCH - NN*60` / `NOW_EPOCH - NN*3600`

Set `START_EPOCH` + `START_SOURCE="--start flag"` and jump to Step 3.5.

### Step 3.1 — (a) SessionStart hook record

The bundled hook (see the bottom of this document) appends one row per session
start to `$SESS_TSV` with columns `epoch iso session_id source cwd transcript`.
Pick the most recent **non-ignored-source** row for **this working directory**,
constrained to today:

```bash
IGNORE_RE=$(jq -r '(.session_skill.session_start.ignore_sources // ["compact"]) | join("|")' "$CONFIG_FILE")

if [ -f "$SESS_TSV" ]; then
  START_EPOCH=$(awk -F '\t' -v cwd="$PWD_NOW" -v today="$TODAY" -v ct="$CONSTRAIN_TODAY" -v ig="$IGNORE_RE" '
    NR>1 && $5==cwd && $4 !~ ("^(" ig ")$") {
      day=substr($2,1,10)
      if (ct!="true" || day==today) { if ($1+0>best) best=$1+0 }
    } END { if (best>0) print best }' "$SESS_TSV")
  if [ -n "$START_EPOCH" ]; then
    START_SOURCE="SessionStart hook (this project)"
  else
    # Relaxed: latest non-ignored row today regardless of cwd (single-session day).
    START_EPOCH=$(awk -F '\t' -v today="$TODAY" -v ct="$CONSTRAIN_TODAY" -v ig="$IGNORE_RE" '
      NR>1 && $4 !~ ("^(" ig ")$") {
        day=substr($2,1,10)
        if (ct!="true" || day==today) { if ($1+0>best) best=$1+0 }
      } END { if (best>0) print best }' "$SESS_TSV")
    [ -n "$START_EPOCH" ] && START_SOURCE="SessionStart hook (latest today — cwd not matched)"
  fi
fi
```

A future-timestamp guard: if `START_EPOCH > NOW_EPOCH` (clock skew), discard it
and fall through.

### Step 3.2 — (b) End of today's last timelog

When there is no hook record (e.g. the plugin was installed mid-session, so the
hook never fired for this session), propose picking up where the timesheet left
off — exactly the cursor anchor `teamwork-task` uses:

```bash
# (parse_iso definition from above goes here — same Bash call.)
LAST_LOG_END=""
if [ -n "$USER_ID" ]; then
  # `orderBy=date` is the valid timelog sort (`orderBy=dateTime` answers 400).
  RESP=$(curl -sS -u "$AUTH" -H "Accept: application/json" -w '\n%{http_code}' \
    "${BASE}/projects/api/v3/time.json?assignedToUserIds=${USER_ID}&pageSize=1&orderBy=date&orderMode=desc&startDate=${TODAY}")
  HTTP=${RESP##*$'\n'}; RESP=${RESP%$'\n'*}
  if [ "$HTTP" != "200" ]; then
    echo "⚠ GET time.json → HTTP $HTTP: $(jq -r '.errors[0].detail // .message // empty' <<<"$RESP" 2>/dev/null) — no last-timelog start, and Step 9 has no overlap anchor unless this read succeeds" >&2
  else
    LAST_LOGGED=$(jq -r '.timelogs[0].timeLogged // empty' <<<"$RESP")
    LAST_MIN=$(   jq -r '.timelogs[0].minutes    // 0'     <<<"$RESP")
    if [ -n "$LAST_LOGGED" ]; then
      LAST_TS=$(parse_iso "$LAST_LOGGED")
      if [ -n "$LAST_TS" ]; then
        CAND=$(( LAST_TS + LAST_MIN * 60 ))
        if [ "$CAND" -le "$NOW_EPOCH" ]; then
          LAST_LOG_END="$CAND"
          if [ -z "$START_EPOCH" ]; then
            START_EPOCH="$CAND"; START_SOURCE="end of today's last timelog"
          fi
        fi
      else
        echo "⚠ could not parse timeLogged '$LAST_LOGGED' from time.json — no last-timelog anchor" >&2
      fi
    fi
  fi
fi
```

`LAST_LOG_END` (this `CAND`, when present) is read **even when the hook record
won the detection** — it is the anchor of the overlap clamp in Step 9, and a
session that started before the last logged block ended must not be billed
twice.

### Step 3.3 — (c) Newest session transcript

Best-effort: Claude Code stores per-session transcripts as `*.jsonl` under
`~/.claude/projects/<encoded-cwd>/`. The first entry's `timestamp` is the
session start.

```bash
# (parse_iso definition from above goes here — same Bash call.)
if [ -z "$START_EPOCH" ]; then
  ENC=$(printf '%s' "$PWD_NOW" | sed 's#[/._]#-#g')
  PROJ_DIR="$HOME/.claude/projects/$ENC"
  if [ -d "$PROJ_DIR" ]; then
    # `find`, not a bare `"$PROJ_DIR"/*.jsonl` glob — with no match zsh aborts
    # the command with "no matches found" before `2>/dev/null` can apply.
    NEWEST=$(find "$PROJ_DIR" -maxdepth 1 -type f -name '*.jsonl' -exec ls -t {} + 2>/dev/null | head -1)
    if [ -n "$NEWEST" ]; then
      FIRST_TS=$(grep -m1 -oE '"timestamp"[: ]*"[^"]+"' "$NEWEST" 2>/dev/null | head -1 | sed -nE 's/.*"([^"]+)"$/\1/p')
      [ -n "$FIRST_TS" ] && START_EPOCH=$(parse_iso "$FIRST_TS")
      [ -n "$START_EPOCH" ] && START_SOURCE="newest session transcript (first entry)"
    fi
  fi
fi
```

### Step 3.4 — (d) Ask

If still empty, ask via **AskUserQuestion**: *"Odkedy si na tomto pracoval?
Neviem zistiť začiatok session automaticky."* Offer concrete options computed in
bash so the user can pick instead of typing a timestamp:

- `pred 30 min` → `NOW_EPOCH - 1800`
- `pred 1 h` → `NOW_EPOCH - 3600`
- `pred 2 h` → `NOW_EPOCH - 7200`
- `Iný čas (HH:MM alebo "45m ago")` → free-form, parse like `--start`

Set `START_SOURCE="user answer"`.

### Step 3.5 — Confirm / edit the window

Unless `--write-back=auto` **and** `--start` were both given, always confirm.
Render:

```
🕒 Session window
   Start:  <HH:MM>  (<START_SOURCE>)
   End:    <HH:MM>  (teraz)
   Trvanie: <human duration, e.g. "1 h 25 min">
```

Then **AskUserQuestion**:

- **Potvrdiť** — use this window
- **Upraviť štart** — free-form (`HH:MM` / `"NNm ago"` / ISO), re-render
- **Od posledného logu** — set start to `LAST_LOG_END` if known (shown only when
  it differs from the current start)
- **Nelogovať čas** — set `LOG_TIME_ENABLED=false`, keep building the task
  without a time log

Store the confirmed `SESSION_START_EPOCH`. If
`(NOW_EPOCH - SESSION_START_EPOCH) / 3600 > max_session_hours_warn`, add a
visible warning to the preview ("dlhá session — over čas pred logom") but do not
block.

---

## Step 4 — Reconstruct what the session accomplished

The **session itself is the source of truth**. You (Claude) already know what
was done — you did it. Corroborate and enrich that knowledge with the repo
state so the task description is concrete (real file paths, real commit hashes),
not a vague paraphrase.

### Step 4.1 — Git evidence since the session start

Only when the cwd is a git repo (`git rev-parse --is-inside-work-tree`):

```bash
SINCE_ISO=$(date -r "$SESSION_START_EPOCH" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null || date -d "@$SESSION_START_EPOCH" +"%Y-%m-%dT%H:%M:%S")
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

# Commits authored during the session window, on the current branch.
SESSION_COMMITS=$(git log --since="$SINCE_ISO" --pretty='%h%x09%s' 2>/dev/null)

# Net changed files across those commits + the still-dirty working tree.
SESSION_FILES=$( { git log --since="$SINCE_ISO" --name-only --pretty=format: 2>/dev/null;
                   git diff --name-only 2>/dev/null;
                   git diff --name-only --cached 2>/dev/null; } | sort -u | sed '/^$/d')

# A compact diffstat for the preview (commits + uncommitted), best-effort.
SESSION_DIFFSTAT=$(git diff --stat "@{u}" 2>/dev/null || git diff --stat 2>/dev/null)
```

Notes:
- `--since` filters by commit timestamp; on a fast session the commits may carry
  timestamps slightly before `SESSION_START_EPOCH` — if `SESSION_COMMITS` is
  empty but the working tree is dirty, fall back to "uncommitted work only".
- If the session produced **no** git changes at all (pure investigation /
  discussion), that is fine — the description is built from the conversation
  context alone, and the technical section records findings instead of a diff.
- This skill **reads** git; it never commits, stages, or pushes.

### Step 4.2 — Repo shape

```bash
[ -f composer.json ] && jq -r '.name // empty' composer.json 2>/dev/null
[ -f package.json ]  && jq -r '.name // empty' package.json  2>/dev/null
[ -d wamesk ]        && ls -1 wamesk   2>/dev/null | head -20
[ -d Modules ]       && ls -1 Modules  2>/dev/null | head -20
```

The detected stack (Laravel modular / Vue / Ionic / Nuxt / …) goes into the
`### Stack & scope` part of the technical section.

Also read the **installed** framework / language versions from the files, never
from memory. With Laravel Boost installed, its `application-info` tool also
reports the PHP, Laravel and main package versions. It does not report
browserslist, Node, Vite, TypeScript or Nuxt, so run the snippet anyway. The
versions back the `Framework:` line of Step 6.2b:

```bash
# Installed framework / language versions — read from the files, never from memory.
# ROOT = the nearest directory from here up to the git root that holds a manifest
# (the Laravel / JS app may live in a subdirectory of the repository).
TOP=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)
ROOT=$(pwd -P)
while [ ! -f "$ROOT/composer.json" ] && [ ! -f "$ROOT/package.json" ] \
      && [ "$ROOT" != "$TOP" ] && [ "$ROOT" != "/" ]; do
  ROOT=$(dirname "$ROOT")
done
FOUND=0
if [ -f "$ROOT/composer.json" ]; then
  FOUND=1
  jq -r '"php " + ((.config.platform.php // .require.php // "?") | tostring)' "$ROOT/composer.json" \
    || echo "⚠ $ROOT/composer.json is not valid JSON — PHP version unknown" >&2
fi
if [ -f "$ROOT/composer.lock" ]; then
  jq -r '[(.packages // [])[], (."packages-dev" // [])[]][]
         | select(.name | test("^(laravel/(framework|nova)|livewire/livewire|inertiajs/inertia-laravel|pestphp/pest)$"))
         | "\(.name) \(.version)"' "$ROOT/composer.lock" \
    || echo "⚠ $ROOT/composer.lock is not valid JSON — Composer versions unknown" >&2
fi
NPM_RE='^(vue|nuxt|react|tailwindcss|vite|typescript|@ionic/vue|@inertiajs/vue3)$'
if [ -f "$ROOT/package-lock.json" ]; then
  FOUND=1
  # lockfileVersion 2/3 list `packages["node_modules/<name>"]`; version 1 only `dependencies`.
  jq -r --arg re "$NPM_RE" 'if has("packages")
           then (.packages | to_entries[] | select(.key | startswith("node_modules/"))
                 | {n: (.key | ltrimstr("node_modules/")), v: .value.version})
           else ((.dependencies // {}) | to_entries[] | {n: .key, v: .value.version}) end
         | select(.n | test($re)) | "\(.n) \(.v)"' "$ROOT/package-lock.json" \
    || echo "⚠ $ROOT/package-lock.json is not valid JSON — npm versions unknown" >&2
elif [ -f "$ROOT/package.json" ]; then
  FOUND=1
  jq -r --arg re "$NPM_RE" '((.dependencies // {}) + (.devDependencies // {})) | to_entries[]
         | select(.key | test($re)) | "\(.key) \(.value) (declared, no package-lock.json)"' "$ROOT/package.json" \
    || echo "⚠ $ROOT/package.json is not valid JSON — npm versions unknown" >&2
fi
[ -f "$ROOT/package.json" ] && jq -r '.browserslist // empty
  | if type == "array" then join(", ") else tostring end | "browserslist: " + .' "$ROOT/package.json"
[ -f "$ROOT/.browserslistrc" ] && grep -Ev '^[[:space:]]*(#|$|\[)' "$ROOT/.browserslistrc" | sed 's/^/browserslist: /'
[ -f "$ROOT/.nvmrc" ] && printf 'node %s\n' "$(head -n 1 "$ROOT/.nvmrc")"
[ "$FOUND" = "0" ] && echo "framework: no composer.json / package.json between $(pwd -P) and $TOP — use the generic line"
echo "framework root: $ROOT"
true
```

### Step 4.3 — Conversation context

Use your own memory of this session as the primary input: what problem was
being solved, which decisions were made and why, what was tried and rejected,
what is still open. The git evidence is the *skeleton*; the conversation is the
*intent*. Combine both in Step 6.

---

## Step 5 — Resolve the target (where to create the work)

### Step 5.1 — No URL → ask

If Step 1 produced no valid URL, **AskUserQuestion**:

> "Kam mám založiť task z tejto session? Vlož Teamwork URL — projekt, tasklist
> alebo konkrétny task (task = práca sa pridá ako jeho subtask)."

Re-parse the answer with the Step 1 parser. If still unparseable, ask once more,
then stop.

### Step 5.2 — Project URL (`URL_KIND=project`)

```bash
PROJECT_ID="$ENTITY_ID"
RESP=$(curl -sS -u "$AUTH" -H "Accept: application/json" -w '\n%{http_code}' \
  "${BASE}/projects/api/v3/projects/${PROJECT_ID}.json")
HTTP=${RESP##*$'\n'}; P_JSON=${RESP%$'\n'*}
if [ "$HTTP" != "200" ]; then
  echo "❌ GET projects/${PROJECT_ID}.json → HTTP $HTTP — no access or wrong URL; stopping" >&2; exit 1
fi
PROJECT_NAME=$(jq -r '.project.name // ""' <<<"$P_JSON")

RESP=$(curl -sS -u "$AUTH" -H "Accept: application/json" -w '\n%{http_code}' \
  "${BASE}/projects/api/v3/projects/${PROJECT_ID}/tasklists.json?pageSize=100")
HTTP=${RESP##*$'\n'}; TLS=${RESP%$'\n'*}
if [ "$HTTP" != "200" ]; then
  echo "❌ GET projects/${PROJECT_ID}/tasklists.json → HTTP $HTTP — cannot list tasklists; stopping" >&2; exit 1
fi
```

- Exactly one tasklist → use it without asking.
- Multiple → **AskUserQuestion** (label = tasklist name, description = task
  count). Cap at 12 visible; offer a "More…" free-form for longer lists.

Set `TASKLIST_ID`, `TASKLIST_NAME`. `TARGET_MODE="main_in_tasklist"`.

### Step 5.3 — Tasklist URL (`URL_KIND=tasklist`)

```bash
TASKLIST_ID="$ENTITY_ID"
# ?include=projects — `.tasklist.project` is only a {id, type} reference; the
# project NAME exists only under `.included.projects["<id>"]`.
RESP=$(curl -sS -u "$AUTH" -H "Accept: application/json" -w '\n%{http_code}' \
  "${BASE}/projects/api/v3/tasklists/${TASKLIST_ID}.json?include=projects")
HTTP=${RESP##*$'\n'}; TL_JSON=${RESP%$'\n'*}
if [ "$HTTP" != "200" ]; then
  # A completed tasklist answers 404 as well — ask for an active one.
  echo "❌ GET tasklists/${TASKLIST_ID}.json → HTTP $HTTP — no access, wrong URL, or a completed tasklist; stopping" >&2; exit 1
fi
TASKLIST_NAME=$(jq -r '.tasklist.name // ""'      <<<"$TL_JSON")
PROJECT_ID=$(   jq -r '.tasklist.projectId // .tasklist.project.id // empty' <<<"$TL_JSON")
PROJECT_NAME=$( jq -r --arg p "$PROJECT_ID" '(.included.projects // {})[$p].name // ""' <<<"$TL_JSON")
TARGET_MODE="main_in_tasklist"
```

### Step 5.4 — Task URL (`URL_KIND=task`) → subtask mode

A task URL means **"file the session work as a subtask of that task"**.

```bash
PARENT_TASK_ID="$ENTITY_ID"
RESP=$(curl -sS -u "$AUTH" -H "Accept: application/json" -w '\n%{http_code}' \
  "${BASE}/projects/api/v3/tasks/${PARENT_TASK_ID}.json?include=tasklists,projects")
HTTP=${RESP##*$'\n'}; PT_JSON=${RESP%$'\n'*}
if [ "$HTTP" != "200" ]; then
  echo "❌ GET tasks/${PARENT_TASK_ID}.json → HTTP $HTTP — no access or wrong URL; stopping" >&2; exit 1
fi
PARENT_TASK_NAME=$(jq -r '.task.name // ""'        <<<"$PT_JSON")
TASKLIST_ID=$(     jq -r '.task.tasklistId // .task.tasklist.id // empty' <<<"$PT_JSON")
# A v3 task object has NO `projectId` key (jq yields null — verified live). The
# project id lives in the tasklist reference, `.task.tasklist.meta.projectId`,
# and in `.included.tasklists["<id>"].projectId` thanks to ?include=tasklists.
# `.task.projectId` stays first only in case a future API version adds it.
PROJECT_ID=$(      jq -r '.task.projectId
                          // .task.tasklist.meta.projectId
                          // ((.included.tasklists // {}) | to_entries[0].value.projectId)
                          // empty' <<<"$PT_JSON")
TASKLIST_NAME=$(   jq -r '.task.tasklist.meta.name
                          // ((.included.tasklists // {}) | to_entries[0].value.name)
                          // ""' <<<"$PT_JSON")
PROJECT_NAME=$(    jq -r --arg p "$PROJECT_ID" '(.included.projects // {})[$p].name // ""' <<<"$PT_JSON")
if [ -z "$PROJECT_ID" ]; then
  echo "⚠ parent task #${PARENT_TASK_ID}: no project id in .task.tasklist.meta or included.tasklists — the Step 14.1 board move will be skipped" >&2
fi
TARGET_MODE="subtask_of_parent"
```

Until 1.3.0 this read `.task.projectId` alone, which v3 never returns: in
subtask mode `PROJECT_ID` was always empty, the Step 10 preview showed an empty
project, and Step 14.1 asked `workflows.json?projectIds=` — which answers
**HTTP 200 with 50 workflows of unrelated projects**, so `.workflows[0]` was a
stranger's board.

In subtask mode the **primary created task** (the one that gets the time log) is
the subtask. Subtask-of-subtask splitting from Step 6.3 is still allowed (the
parent already exists; we hang the session work — and any further breakdown —
under it).

Stop with a clear error on HTTP 403/404 on any target lookup.

---

## Step 6 — Synthesise the task concept

Inputs: the git evidence (Step 4.1), repo shape (4.2), conversation context
(4.3), language, and the section labels. Produce a draft:

### Step 6.1 — Title

Short, business-friendly, ≤ 90 chars, describing **what was delivered** (not
"session" jargon). Examples:

- `Export faktúr do CSV s podporou témy nájomcu`
- `Oprava výpadku prihlasovania pri súbežnom obnovení relácie`

In subtask mode, prefix with a role tag when obvious (`[BE]`, `[FE]`, …).

### Step 6.2 — Description (canonical WAME format)

**The estimate never appears in the description or in the title.** The minutes
belong in the Teamwork estimate field (`estimatedMinutes`, Step 11) and nowhere
else — an estimate duplicated into prose has to be edited in two places and the
two then disagree. Do not write `Odhad: <N> min`, `Estimate: <N>h`, or any
minute/hour figure into the preamble, the AC, the Goal, the technical section,
or the `### {SRC_LABEL}` footer. Showing it in the Step 10 preview and the
Step 15 report is correct and stays.

```
[optional preamble — only if there is genuinely useful free-text context that
does not fit the structured sections; otherwise omit entirely]

---

## {ACC_LABEL}
- [ ] AC 1 — atomic, testable, written from the user's perspective
- [ ] AC 2 — …

### Prierezové požiadavky
- [ ] **Dostupnosť (reachability):** <outcome the session delivered> (<evidence: `path:line` / commit>)
- [ ] **Bezpečnosť (security):** <applicable requirement> — *nepokryté v tejto session*

---

## {GOAL_LABEL}
2–4 sentences. WHY this work matters (business / user outcome), not how.

---

## {TECH_LABEL}

### Stack & scope
Detected stack; modules/files actually touched (`path/to/file.php:line`).

### Step-by-step
What was done, in order — derived from the commits + the conversation. Written
so another engineer could reproduce or extend it.

### Data model / schema changes
Tables/columns/migrations touched, or "none".

### Edge cases & risks
What was handled; what is still risky.

### Kvalita (UI/UX, výkon, bezpečnosť, dostupnosť, framework)
One line of *how* per applicable dimension (Step 6.2a) — where the menu entry /
inbound link is registered, which policy guards the new action, which eager-load
/ index / pagination keeps the list fast, which lang file holds the new strings.
Plus one `Framework:` line when the session wrote code (Step 6.2b) — the
installed versions and the idioms the diff actually uses, with evidence.
Omit dimensions that do not apply; omit the whole subsection when none does and
no code was written.

### Tests to add / added
Which tests exist now, which are still worth adding.

### {SRC_LABEL}
- Session: /teamwork-tasks-from-session on <YYYY-MM-DD>
- Branch: <BRANCH>
- Commits (<n>):
  - <hash> <subject>
  - …
```

The `### {SRC_LABEL}` block records the branch and the session commits (capped
at `link_session.max_commits_listed`) so the task is traceable to the actual
change set. Omit the commits line when there were none.

### Step 6.2a — Cross-cutting requirements (`Prierezové požiadavky`)

Acceptance criteria written from the feature's point of view almost never ask
whether the new screen can be *found*, who may press the new button, or what the
list does at 10 000 rows — and `teamwork-task-test` checks exactly those four
things at QA time (its Step 6.6 dimensions `ui_ux`, `performance`, `security`,
`reachability`). Name them in the task so the QA side and the build side read
the same list. Add only the dimensions that **apply** to this change — a pure
backend fix grows no UI lines, a copy change grows none at all, and then the
sub-heading is omitted.

| Key | Applies when the change … | The criterion states (sk example) |
|---|---|---|
| `reachability` | adds, renames or removes a screen — page, route rendering a view, Nova resource / lens / dashboard / tool, SPA route | „Obrazovka *Splátky* je dostupná z menu *Fakturácia* pre rolu X a z detailu zmluvy (záložka / odkaz)." A deliberately URL-only page says so („len cez odkaz z e-mailu, zámerne bez menu"). A rename / removal: „Žiadna položka menu ani odkaz z inej obrazovky nevedie na zrušenú adresu." |
| `security` | adds a route, action, button, endpoint or form input | „Akciu vidí a spustí len rola X a len nad záznamami vlastnej firmy; cudzí záznam vráti 403, nie 500. Viditeľnosť v menu a autorizácia sa zhodujú." |
| `performance` | adds or changes a list, export, import, report, batch job or data migration over a table that grows | „Zoznam sa pri 10 000 záznamoch načíta stránkovane, bez dopytu na každý riadok." |
| `ui_ux` | changes anything a user sees | „Prázdny, načítavací a chybový stav sú navrhnuté; neaktívne tlačidlo ukazuje dôvod; nové texty idú cez preklady." |

Rules for this skill — the session reconstructs work that is **already done**:

- **State a cross-cutting outcome as delivered only when the diff or the
  conversation proves it.** A menu entry counts when the diff shows the menu
  registration; cite the evidence in parentheses (`path:line` or the commit).
- **Every applicable dimension the session did not cover is still listed**, as a
  requirement suffixed `— *nepokryté v tejto session*`
  (en: `— *not covered in this session*`) — never phrased as done. These are the
  items a reviewer would otherwise only find in QA.
- **Every box stays `- [ ]`**, delivered ones included. Ticking is
  `teamwork-task-test`'s job, after it has verified the criterion.
- **Placement is load-bearing:** the `### Prierezové požiadavky` sub-heading sits
  inside the `## {ACC_LABEL}` section — after the feature criteria, before the
  first `---` — because `teamwork-task-test` reads and ticks only the block
  between that heading and the first `---`. Never put a `---` inside it.
- **Labels:** sk — `### Prierezové požiadavky`, `UI/UX (ui_ux)`,
  `Výkon (performance)`, `Bezpečnosť (security)`, `Dostupnosť (reachability)`;
  en — `### Cross-cutting requirements`, `UI/UX (ui_ux)`,
  `Performance (performance)`, `Security (security)`,
  `Reachability (reachability)`. The key in parentheses is the
  `teamwork-task-test` dimension name — keep it. The technical subsection is
  `### Kvalita (UI/UX, výkon, bezpečnosť, dostupnosť, framework)` /
  `### Quality (UI/UX, performance, security, reachability, framework)`.
- **Only these four keys.** The fifth dimension, `framework`, never appears in
  this sub-block — it is technical-plan only (Step 6.2b).
- Uncovered items are **remaining work**, not part of the logged session time.
  Step 10 lists them on a `Zostáva` line; when they are more than a small
  follow-up, offer them as a subtask (Step 6.3 rules) rather than silently
  widening the estimate.

### Step 6.2b — Framework versions and idioms (`framework`) — technical plan only

`teamwork-task` and the laravel agents write new code in the idioms of the
framework versions the project **actually has installed**; `teamwork-task-test`
reviews that as a fifth, **advisory** dimension, `framework` (recommendations
only — it never fails or ticks anything). This skill documents work that is
already done, so the `### Kvalita` subsection gets one `Framework:` line that
records **what the session actually used** — the installed versions from
Step 4.2 and the version-specific idioms the diff shows, each with its evidence:

```
- Framework: Laravel 12.28, PHP 8.3 — enum cast cez `casts()` (`app/Models/Invoice.php:41`), `Rule::enum` vo FormRequest (`app/Http/Requests/StoreInvoiceRequest.php:18`)
```

- **Never claim what the diff does not show.** Name an idiom only when you can
  cite the `path:line` or the commit; never call the change "modern" or "per
  best practices" in general. No code diff (a pure investigation) → no
  `Framework:` line; the versions may still be named under `### Stack & scope`.
  Step 4.2 found no `composer.json` / `package.json` → no version claim; omit
  the line.
- **Checked, not remembered.** Whether something is deprecated in, or newer
  than, the installed version is looked up in current docs — Laravel Boost
  `search-docs` when the project has `laravel/boost`, otherwise context7
  (`resolve-library-id` → `query-docs`), otherwise the official docs / upgrade
  guide of that major version. Model memory of a framework is stale.
- **What the diff could do better is a note, not work.** An API deprecated in
  the installed version, or hand-rolled code for something the installed version
  ships, gets a short `odporúčanie na neskorší refaktor: …` (en: `suggestion for a
  later refactor: …`) after the line — never an acceptance criterion, never a
  *nepokryté* item, never added to `Zostáva` or to the estimate. A feature
  **newer** than the installed version or the browserslist target is different:
  it will not run, so it goes under `### Edge cases & risks` as a real risk.
- **Plan only — never an acceptance criterion.** No `- [ ]` line and no entry
  under `### Prierezové požiadavky`: the tester treats `framework` as advisory,
  so such a box could never be ticked. It costs no clarifying question either.

### Step 6.3 — Subtasks (optional)

Propose subtasks **only** when **all** are true:

1. `--no-subtasks` is not set and `subtasks.enabled == true`.
2. The total estimate exceeds `subtasks.propose_split_threshold_minutes` (240).
3. The work has natural cut points (different layers / components / migration vs
   feature).

Each subtask: a `[BE]/[FE]/[QA]/[Migration]/[DevOps]` prefix + business name, its
own canonical description (no preamble, no `### {SRC_LABEL}` — only the primary
task carries the source block), and its own estimate **written to the
`estimatedMinutes` field only, never into the subtask name or its description**.
Count 2–6. **Never force-split** small sessions.

### Step 6.4 — Estimate

Use the **WAME methodology** (full text at the bottom of this document): one
number per task, picked against the anchors there, rounded to
`estimate.step_minutes` (15) and capped at `estimate.max_task_minutes` (480).
There is no speedup factor and no buffer percentage — version 2 removed both.
When there are subtasks, the main estimate is the **sum** of the subtask
estimates.

The estimate is the *methodology* number — what this work should cost the next
time somebody does it. The logged time is what it actually took this run. They
are independent and both appear in the preview.

**This skill is where the methodology gets its evidence.** It is the only plugin
in the family that puts an estimate and a measured duration next to each other on
the same piece of work. Say so in the preview when they differ by more than half:
one line naming the anchor you used and the real number. When the same kind of
work drifts the same way several runs in a row, the fix is to move that anchor in
the methodology block — never to re-introduce a buffer percentage.

---

## Step 7 — Resolve the assignee (ask for the Teamwork email)

Decide who the new task is assigned to. By default the skill **asks** — the
work is yours, but you may be filing it for a teammate.

If `--assignee=<email>` was passed, use it directly (empty = unassigned) and
skip the question. Otherwise, when `session_skill.assignee.ask == true`, run one
**AskUserQuestion**:

> "Na aký Teamwork email priradiť tento task?"
>
> - **Mňa — `<MY_NAME>` (`<MY_EMAIL>`)** — assign to the current user (shown
>   first when `assignee.default_to_me == true`)
> - **Nepriradené** — leave unassigned (only when `assignee.allow_empty`)
> - **Iný email** — free-form; the user types a colleague's Teamwork email

In subtask mode, when Step 6.3 produced multiple role prefixes, ask one question
per distinct role (batch up to 4 per UI call) so BE / FE / QA can go to
different people. The primary task defaults to the dominant role's assignee.

### Step 7.1 — Resolve email → userId

For each non-empty chosen email:

```bash
EMAIL_ENCODED=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$EMAIL")
RESP=$(curl -sS -u "$AUTH" -H "Accept: application/json" -w '\n%{http_code}' \
  "${BASE}/projects/api/v3/people.json?searchTerm=${EMAIL_ENCODED}&pageSize=10")
HTTP=${RESP##*$'\n'}; RESP=${RESP%$'\n'*}
[ "$HTTP" = "200" ] || echo "⚠ GET people.json → HTTP $HTTP — treating as 0 matches; the next question lets you retry or leave the task unassigned" >&2
# The email travels as a jq --arg, never spliced into the jq program text.
MATCHES=$(jq -r --arg e "$EMAIL" '[ (.people // [])[] | select(((.email // .emailAddress // "")|ascii_downcase) == ($e|ascii_downcase)) ]' <<<"$RESP")
```

- 0 matches → **AskUserQuestion**: `Skús iný email` / `Nechať nepriradené` / `Zrušiť`.
- 1 match → use its `id`.
- 2+ matches → **AskUserQuestion** to pick (label = `<firstName> <lastName>`,
  description = `<email> · <jobTitle>`).

When the chosen email is `MY_EMAIL`, reuse the cached `USER_ID` without a lookup.
Cache resolutions for the run.

---

## Step 8 — Clarifying questions

Same batched pattern as `teamwork-task-analyze` Step 6.2:

- Max `clarifying_questions.max_per_run` total (default 6), batches of 4 per
  **AskUserQuestion** call.
- Ask only what materially changes AC / Goal / Technical plan **and** you cannot
  infer from the session, commits, or repo.
- Fold answers back: behaviour → AC, "why" → Goal, implementation → Technical
  plan.
- Anything unanswered/dropped → preserve as
  `[OTVORENÉ] <question>` markers (configurable) in the relevant section.
- Questions about the cross-cutting requirements (Step 6.2a — which menu
  section, which roles may see the action) come out of the **same** budget.
  Answer them from the repo first (the sibling screens' menu registration, the
  neighbouring policies); ask only what the code cannot tell.

Because the session is your own work, this step is often empty — skip straight to
Step 9 when you have no genuine ambiguity.

---

## Step 9 — Compute the time-log proposal (overlap-safe)

Only when `LOG_TIME_ENABLED != false` (the `--log-time` flag and the Step 3.5
"Nelogovať čas" option both set it false) and `time_log.enabled == true`.

```bash
ROUND=$(jq -r '.time_rounding_minutes // 5' "$CONFIG_FILE"); ROUND_SECS=$((ROUND*60))
THRESHOLD=$(jq -r '.round_threshold_minutes // 4' "$CONFIG_FILE")
MIN_LOG=$(jq -r '.min_log_minutes // 1' "$CONFIG_FILE")
AVOID_OVERLAP=$(jq -r '.session_skill.time_log.avoid_overlap | if . == null then true else . end' "$CONFIG_FILE")

PROPOSED_START=$SESSION_START_EPOCH
OVERLAP_NOTE=""

# Clamp so the new entry never overlaps today's last timelog. LAST_LOG_END was
# captured in Step 3.2 (recompute here if it was not, using the same query).
if [ "$AVOID_OVERLAP" = "true" ] && [ -n "${LAST_LOG_END:-}" ] && [ "$PROPOSED_START" -lt "$LAST_LOG_END" ]; then
  OVERLAP_NOTE="štart pred koncom posledného logu — orezané na $(date -r "$LAST_LOG_END" +%H:%M 2>/dev/null || date -d "@$LAST_LOG_END" +%H:%M), aby sa logy neprekrývali"
  PROPOSED_START=$LAST_LOG_END
fi

DURATION_SECS=$(( NOW_EPOCH - PROPOSED_START ))
RAW_MIN=$(( DURATION_SECS / 60 ))
[ "$RAW_MIN" -lt 0 ] && RAW_MIN=0

# Rounding — identical two-zone logic to teamwork-task Step 6.6:
#   RAW >= THRESHOLD → round to NEAREST multiple of ROUND (half-up)
#   RAW <  THRESHOLD → keep raw minutes (sub-round), provided RAW >= MIN_LOG
TIMELOG_SUB_ROUND=0
if [ "$RAW_MIN" -ge "$THRESHOLD" ]; then
  DURATION_MIN=$(( ( (RAW_MIN + ROUND/2) / ROUND ) * ROUND ))
  [ "$DURATION_MIN" -lt "$ROUND" ] && DURATION_MIN=$ROUND
  [ $(( DURATION_MIN % ROUND )) -ne 0 ] && TIMELOG_SUB_ROUND=1
else
  DURATION_MIN=$RAW_MIN
  TIMELOG_SUB_ROUND=1
fi

# LOCAL formatting on purpose: Teamwork interprets the POST `time` field in the
# user's local/profile timezone (inverse of `timeLogged`, which is UTC). Never
# switch to `date -ju`/`date -u` here — see the TIMEZONE CONTRACT note on parse_iso.
LOG_DATE=$(date -r "$PROPOSED_START" +%Y-%m-%d 2>/dev/null || date -d "@$PROPOSED_START" +%Y-%m-%d)
LOG_TIME=$(date -r "$PROPOSED_START" +%H:%M:%S 2>/dev/null || date -d "@$PROPOSED_START" +%H:%M:%S)
```

Edge cases:

- `DURATION_MIN < MIN_LOG` (essentially zero — the session start equals now, or
  was fully clamped away) → **do not** invent time. Surface it in the preview as
  *"čas na zalogovanie ~0 min"* and offer, via the Step 10 gate, to either skip
  the log or enter a manual minute count.
- `RAW_MIN` over `max_session_hours_warn * 60` → show the long-session warning;
  the log still happens after confirmation.

Decide the **log target** (`time_log.log_target`, default `primary_task`):

- `primary_task` — the whole duration on the primary created task (the main task,
  or the subtask in subtask mode). One entry. This is the default.
- `split_subtasks` — split `DURATION_MIN` across created subtasks proportional to
  their estimates (each share re-rounded to `ROUND`, remainder to the largest).
  Only offered when subtasks exist; mention it as an edit option, do not default
  to it.

---

## Step 10 — Full preview + confirmation gate

Render one markdown block covering **everything** that will be written. Nothing
is created before the user approves.

```markdown
## Návrh — task z tejto session

**Cieľ:** <PROJECT_NAME> (#<PROJECT_ID>) › <TASKLIST_NAME> (#<TASKLIST_ID>)
<in subtask mode:> **Rodičovský task:** <PARENT_TASK_NAME> (#<PARENT_TASK_ID>) — práca pôjde ako subtask

### Hlavný task <or "Subtask">
- **Názov:** <TITLE>
- **Odhad (metodika):** <EST> min (~<H> h)
- **Priradené:** <name / "nepriradené">
- **Popis:**

  <full canonical-format description, fenced>

### Subtasky (<N>)
1. **[BE]** <name> — <est> min — <assignee>
   - AC: <first AC>; <second AC>; …
2. …

### Prierezové požiadavky
- Doručené v session: <n> — <dimension keys>
- Zostáva: <n> — <dimension keys, or "nič">  (not in the logged time; follow-up subtask?)

### ⏱ Čas na zalogovanie
- Štart:   <LOG_TIME> (<START_SOURCE>)
- Koniec:  <now HH:MM>
- Trvanie: **<DURATION_MIN> min**  (raw <RAW_MIN> min)
- <OVERLAP_NOTE, if any>
- Loguje sa na: <primary task title>
- Billable: <yes/no>
- <"⚠ dlhá session — over čas" when over the warn threshold>

### Po vytvorení (board)
- <"Spýtam sa" when board.after_create == ask, else the configured action;
  for move-done name the target column — `DONE_CHAIN` from Step 14, e.g.
  "Done - Local (ak ho board nemá: Internal testing → Testing)">
```

Then **AskUserQuestion**:

- **Vytvoriť** — proceed to Step 11
- **Upraviť task** — free-form corrections, re-render
- **Upraviť subtask N** — same, per subtask
- **Upraviť čas** — re-open the Step 9 numbers (change start / minutes / skip log)
- **Bez subtaskov** — drop the split, keep only the primary task
- **Zrušiť** — stop without any write

`--write-back=never` → stop after rendering this preview (full dry-run: nothing
created, **no time logged**). `--write-back=auto` → skip this question and
proceed (the user pre-approved the numbers via flags).

---

## Step 11 — Create the primary task

The primary task is the **main task** (`TARGET_MODE=main_in_tasklist`) or the
**subtask of the parent** (`TARGET_MODE=subtask_of_parent`). Same POST either
way; subtask mode just adds `parentTaskId`.

**Carried-over field lessons from `teamwork-tasks-from-desk` 1.0.1:**

1. **Encode the JSON payload with Python**, not `jq -n --arg` — `json.dump(...,
   ensure_ascii=False)` handles multi-line Slovak descriptions without leaking
   control characters into `curl`.
2. The **write** field for the estimate is `estimatedMinutes` (with a `d`); the
   read field `estimateMinutes` is silently accepted on POST but lands as 0. Use
   the persisted `session_skill.task_create_estimate_field`.
3. **Idempotency guard:** if response parsing throws, the task may already exist
   — search the tasklist by name (created in the last ~60 s) before retrying.
   v3 task objects carry `createdAt` (not `dateCreated`).
4. **The task name reaches Python through a file, never through the Python
   source.** Until 1.3.0 this step spliced `${PRIMARY_NAME@Q}` into the heredoc:
   that expansion is `bad substitution` in zsh (the shell Claude Code runs on
   macOS) and in macOS bash 3.2, so the whole `python3` command never ran, no
   payload was written and **no task could be created**; on bash 4.4+ it ran, but
   shell quoting is not Python quoting, so a crafted name could break out.
   Same pattern `teamwork-tasks-from-desk` adopted in 1.0.2.

```bash
EST_FIELD=$(jq -r '.session_skill.task_create_estimate_field // "estimatedMinutes"' "$CONFIG_FILE")

NAME_PATH="$(mktemp)"; printf '%s' "$PRIMARY_NAME" > "$NAME_PATH"
DESC_PATH="$(mktemp)"; printf '%s' "$PRIMARY_DESC" > "$DESC_PATH"
PAYLOAD_PATH="$(mktemp)"
# The heredoc interpolates only trusted shell values (the field name and
# integers). Name and description are read raw from the temp files.
python3 - "$NAME_PATH" "$DESC_PATH" "$PAYLOAD_PATH" <<PY
import json, sys
name = open(sys.argv[1], encoding="utf-8").read()
desc = open(sys.argv[2], encoding="utf-8").read()
payload = {"task": {
    "name":           name,
    "description":    desc,
    "${EST_FIELD}":   ${PRIMARY_EST},
}}
aid = ${PRIMARY_ASSIGNEE_ID:-0}
if aid: payload["task"]["assignees"] = {"userIds": [aid]}
pid = ${PARENT_TASK_ID:-0}
if pid: payload["task"]["parentTaskId"] = pid
json.dump(payload, open(sys.argv[3], "w", encoding="utf-8"), ensure_ascii=False)
PY

HTTP=$(curl -sS -u "$AUTH" -H "Content-Type: application/json" -H "Accept: application/json" \
  -X POST -d @"$PAYLOAD_PATH" -o /tmp/tws_main.json -w '%{http_code}' \
  "${BASE}/projects/api/v3/tasklists/${TASKLIST_ID}/tasks.json")

PRIMARY_TASK_ID=$(python3 -c "import json;d=json.load(open('/tmp/tws_main.json'));t=d.get('task',d);print(t.get('id') or '')")

if [ -z "$PRIMARY_TASK_ID" ]; then
  # Idempotency probe before giving up / retrying.
  NAME_ENC=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$PRIMARY_NAME")
  PRIMARY_TASK_ID=$(curl -sS -u "$AUTH" -H "Accept: application/json" \
    "${BASE}/projects/api/v3/tasklists/${TASKLIST_ID}/tasks.json?searchTerm=${NAME_ENC}&pageSize=5" \
    | python3 -c "
import json,sys,datetime
want=open(sys.argv[1], encoding='utf-8').read()
d=json.load(sys.stdin); now=datetime.datetime.utcnow()
for t in d.get('tasks',[]):
    if t.get('name')==want:
        ts=(t.get('createdAt') or t.get('dateCreated') or '').rstrip('Z')
        try:
            if (now-datetime.datetime.strptime(ts,'%Y-%m-%dT%H:%M:%S')).total_seconds()<120:
                print(t['id']); break
        except Exception: pass" "$NAME_PATH")
fi

if [ -z "$PRIMARY_TASK_ID" ]; then
  echo "❌ Primary task creation failed (HTTP ${HTTP}):"; head -c 1000 /tmp/tws_main.json; exit 1
fi
PRIMARY_TASK_URL="${BASE}/app/tasks/${PRIMARY_TASK_ID}"
echo "✅ Vytvorený task: ${PRIMARY_NAME} (#${PRIMARY_TASK_ID})"
rm -f "$NAME_PATH" "$DESC_PATH" "$PAYLOAD_PATH"
```

Non-2xx with no recoverable id → render the error body and stop. This is the
load-bearing call; everything after it is best-effort and non-fatal.

---

## Step 12 — Create subtasks

For each confirmed subtask from Step 6.3, in order. Same Python-encoded payload
and `estimatedMinutes` field as Step 11, with `parentTaskId = PRIMARY_TASK_ID`
and the per-role assignee resolved in Step 7.

```bash
SUB_ROLE=$(printf '%s' "$SUB_NAME" | sed -nE 's|^\[([A-Za-z]+)\].*|\1|p')
SUB_ASSIGNEE_ID=$(jq -r --arg r "$SUB_ROLE" '.[$r] // ""' <<<"$ASSIGNEE_MAP")
[ -z "$SUB_ASSIGNEE_ID" ] && SUB_ASSIGNEE_ID="${PRIMARY_ASSIGNEE_ID:-}"

# Name and description via temp files, the server response via stdin — never
# `${SUB_NAME@Q}` / `${SUB_RESP@Q}` spliced into Python source (see Step 11,
# lesson 4: `bad substitution` in zsh and bash 3.2).
SUB_NAME_PATH="$(mktemp)"; printf '%s' "$SUB_NAME" > "$SUB_NAME_PATH"
SUB_DESC_PATH="$(mktemp)"; printf '%s' "$SUB_DESC" > "$SUB_DESC_PATH"
SUB_PAYLOAD_PATH="$(mktemp)"
python3 - "$SUB_NAME_PATH" "$SUB_DESC_PATH" "$SUB_PAYLOAD_PATH" <<PY
import json, sys
name = open(sys.argv[1], encoding="utf-8").read()
desc = open(sys.argv[2], encoding="utf-8").read()
payload = {"task": {
    "name":          name,
    "description":   desc,
    "${EST_FIELD}":  ${SUB_EST},
    "parentTaskId":  ${PRIMARY_TASK_ID},
}}
uid = ${SUB_ASSIGNEE_ID:-0}
if uid: payload["task"]["assignees"] = {"userIds": [uid]}
json.dump(payload, open(sys.argv[3], "w", encoding="utf-8"), ensure_ascii=False)
PY

SUB_RESP=$(curl -sS -u "$AUTH" -H "Content-Type: application/json" -H "Accept: application/json" \
  -X POST -d @"$SUB_PAYLOAD_PATH" \
  "${BASE}/projects/api/v3/tasklists/${TASKLIST_ID}/tasks.json")
SUB_ID=$(printf '%s' "$SUB_RESP" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(0)          # not JSON -> empty id -> reported as a failure below
t = d.get('task', d)
print(t.get('id') or '')")
if [ -n "$SUB_ID" ]; then SUBTASK_IDS+=("$SUB_ID"); echo "✅ Subtask: ${SUB_NAME} (#${SUB_ID})";
else SUBTASK_FAILURES+=("${SUB_NAME}: $(printf '%s' "$SUB_RESP" | head -c 300)"); echo "❌ Subtask zlyhal: ${SUB_NAME}"; fi
rm -f "$SUB_NAME_PATH" "$SUB_DESC_PATH" "$SUB_PAYLOAD_PATH"
```

Per-subtask failure is non-fatal — log and continue.

---

## Step 13 — Log the session time

Skip entirely when `LOG_TIME_ENABLED == false` or `DURATION_MIN < MIN_LOG`
(record `⏭ nelogované` in the report). Otherwise post **one** entry to the
**primary task** (or split across subtasks when `log_target == split_subtasks`):

`POST ${BASE}/projects/api/v3/tasks/${PRIMARY_TASK_ID}/time.json`

**Business-tone description** (same rule as `teamwork-task` Step 6.8): write what
was delivered for the user/business, 1–2 sentences in `default_language`,
technical detail only when it helps identify the work. Append `(commit: <hash>)`
for the session's most relevant commit when
`include_commit_hash_in_log_description == true`.

```bash
# `// true` would read a deliberate `false` as `true` (jq's `//` skips false too).
BILLABLE=$(jq -r '.is_billable_by_default | if . == null then true else . end' "$CONFIG_FILE")
INCL_HASH=$(jq -r '.include_commit_hash_in_log_description | if . == null then true else . end' "$CONFIG_FILE")

DESCRIPTION="$DESCRIPTION_BUSINESS"
if [ "$INCL_HASH" = "true" ] && [ -n "${LAST_SESSION_COMMIT:-}" ]; then
  DESCRIPTION="${DESCRIPTION} (commit: ${LAST_SESSION_COMMIT})"
fi

PAYLOAD=$(jq -nc \
  --argjson minutes "$DURATION_MIN" \
  --arg desc "$DESCRIPTION" \
  --arg date "$LOG_DATE" \
  --arg time "$LOG_TIME" \
  --argjson billable "$BILLABLE" \
  '{timelog: {hours: 0, minutes: $minutes, description: $desc, date: $date, time: $time, isbillable: $billable}}')

HTTP=$(curl -sS -o /tmp/tws_time.json -w "%{http_code}" -u "$AUTH" \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -X POST -d "$PAYLOAD" \
  "${BASE}/projects/api/v3/tasks/${PRIMARY_TASK_ID}/time.json")

if [ "$HTTP" -ge 200 ] && [ "$HTTP" -lt 300 ]; then
  TIMELOG_OK=1; echo "✅ Zalogované ${DURATION_MIN} min od ${LOG_TIME} na #${PRIMARY_TASK_ID}"
else
  TIMELOG_OK=0; echo "⚠ time log POST failed (HTTP $HTTP)"; head -c 500 /tmp/tws_time.json
fi
```

The entry's start = `LOG_TIME`, duration = `DURATION_MIN` — both derived from the
overlap-clamped `PROPOSED_START`, so the result is contiguous with the rest of
today's timesheet (no gaps, no overlaps). On non-2xx, report and continue — the
task already exists; do not blindly retry.

For `split_subtasks`, loop the per-subtask shares, advancing a local cursor by
each logged share so the sub-entries are themselves non-overlapping.

---

## Step 14 — Board action (asked per run)

`BOARD_ACTION` comes from `--board` → `session_skill.board.after_create`
(default `ask`).

The done column comes from the **shared** `board_workflow` keys that
`teamwork-task` also moves cards with *(1.3.0)* — `done_stage` (default
`Done - Local`, the end column of the WAME board) and `done_stage_fallbacks`
(default `Internal testing`, then `Testing`, so an older per-project board keeps
landing where it did). A customised `session_skill.board.done_stage` /
`done_stage_fallbacks` / `match_mode` (Step 2.5) still overrides them for this
skill only. Name the configured chain in the question:

```bash
DONE_CHAIN=$(jq -r '[.session_skill.board.done_stage // .board_workflow.done_stage // "Done - Local"]
  + ((.session_skill.board.done_stage_fallbacks // .board_workflow.done_stage_fallbacks
      // ["Internal testing", "Testing"]) | if type == "string" then [.] else . end)
  | .[0] + (if length > 1 then " (ak ho board nemá: " + (.[1:] | join(" → ")) + ")" else "" end)' "$CONFIG_FILE")
```

When `ask`, run one **AskUserQuestion**:

> "Práca je hotová — čo spraviť s taskom na boarde?"
>
> - **Nechať tak** — no board change (default)
> - **Presunúť do „<done_stage>"** — move to the done column; the option
>   description carries `DONE_CHAIN`, e.g. *„Done - Local (ak ho board nemá:
>   Internal testing → Testing)"*
> - **Označiť ako dokončený** — mark the task complete

When the description carries cross-cutting items marked *nepokryté v tejto
session* (Step 6.2a), say so in the question text ("task má <n> nepokrytých
prierezových požiadaviek") — a task with known remaining work should not be
marked complete by reflex.

### Step 14.1 — Move to the done stage

Resolve the project's workflow + done stage by name (in the configured
`match_mode`, default case-insensitive, with fallbacks), then POST the move —
same mechanism and the same `board_workflow` keys as `teamwork-task`. On the
WAME board (workflow "WAME workflow") the default resolves to `Done - Local`; on
an older board without that column it falls back to `Internal testing`, then
`Testing`.

**Guard (1.3.0): never ask for workflows without a project id.**
`workflows.json?projectIds=` with an empty value is not an error — it answers
HTTP 200 with the first 50 workflows of the whole workspace, all belonging to
other projects, and their pooled `included.stages` contain a `Testing` stage. A
blind `.workflows[0]` therefore pointed the move at a stranger's board. Skip the
move when `PROJECT_ID` is empty, pick only a workflow whose `projectIds` lists
this project, and resolve stage names only among **that** workflow's stages.

```bash
BOARD_RESULT=""
# 1.3.0: the shared `board_workflow` keys (owned by teamwork-task) — unless
# Step 2.5 kept a customised `session_skill.board` override for this skill.
DONE_NAME=$(jq -r '.session_skill.board.done_stage // .board_workflow.done_stage // "Done - Local"' "$CONFIG_FILE")
MATCH_MODE=$(jq -r '.session_skill.board.match_mode // .board_workflow.match_mode // "case_insensitive"' "$CONFIG_FILE")
if [ -z "${PROJECT_ID:-}" ]; then
  BOARD_RESULT="skipped — project id unknown (Step 5), refusing to guess a workflow"
  echo "⚠ ${BOARD_RESULT}" >&2
else
  RESP=$(curl -sS -u "$AUTH" -H "Accept: application/json" -w '\n%{http_code}' \
    "${BASE}/projects/api/v3/workflows.json?projectIds=${PROJECT_ID}&include=stages")
  HTTP=${RESP##*$'\n'}; WF_RESP=${RESP%$'\n'*}
  if [ "$HTTP" != "200" ]; then
    BOARD_RESULT="skipped — GET workflows.json → HTTP $HTTP"
    echo "⚠ ${BOARD_RESULT}" >&2
    WF_RESP='{}'
  fi

  # Only a workflow that actually lists this project — never `.workflows[0]`.
  WORKFLOW_ID=$(jq -r --argjson p "$PROJECT_ID" \
    '[.workflows[]? | select(any((.projectIds // [])[]; . == $p))][0].id // empty' <<<"$WF_RESP")

  # Stage names → ids, restricted to the chosen workflow's own stage ids.
  # lowercased name <TAB> name <TAB> id — both sides are lowercased by jq's
  # ascii_downcase, so the needle and the table can never disagree.
  STAGE_TSV=$(mktemp)
  jq -r --arg w "$WORKFLOW_ID" '
    [ .workflows[]? | select((.id|tostring) == $w) | .stages[]?.id | tostring ] as $ids
    | (.included.stages // {})
    | (if type == "object" then [.[]] elif type == "array" then . else [] end)[]
    | select((.id|tostring) as $i | any($ids[]; . == $i))
    | "\((.name // "") | ascii_downcase)\t\(.name // "")\t\(.id)"' <<<"$WF_RESP" > "$STAGE_TSV"

  lookup_stage() {
    if [ "$MATCH_MODE" = "case_sensitive" ]; then
      awk -F '\t' -v n="$1" '$2 == n { print $3; exit }' "$STAGE_TSV"
    else
      awk -F '\t' -v n="$(jq -rn --arg s "$1" '$s | ascii_downcase')" '$1 == n { print $3; exit }' "$STAGE_TSV"
    fi
  }

  DONE_STAGE_ID=$(lookup_stage "$DONE_NAME"); DONE_RESOLVED="$DONE_NAME"
  if [ -z "$DONE_STAGE_ID" ]; then
    while IFS= read -r FB; do
      [ -z "$FB" ] && continue
      C=$(lookup_stage "$FB"); [ -n "$C" ] && { DONE_STAGE_ID="$C"; DONE_RESOLVED="$FB"; break; }
    done < <(jq -r '(.session_skill.board.done_stage_fallbacks // .board_workflow.done_stage_fallbacks
                     // ["Internal testing", "Testing"]) | if type == "string" then [.] else . end | .[]' "$CONFIG_FILE")
  fi

  if [ -n "$BOARD_RESULT" ]; then
    :   # already skipped above, reason recorded
  elif [ -n "$WORKFLOW_ID" ] && [ -n "$DONE_STAGE_ID" ]; then
    HTTP=$(curl -sS -o /dev/null -w '%{http_code}' -u "$AUTH" -H "Content-Type: application/json" \
      -X POST -d "{\"taskIds\":[${PRIMARY_TASK_ID}]}" \
      "${BASE}/projects/api/v3/workflows/${WORKFLOW_ID}/stages/${DONE_STAGE_ID}/tasks.json")
    [ "$HTTP" -ge 200 ] && [ "$HTTP" -lt 300 ] && BOARD_RESULT="moved → ${DONE_RESOLVED}" || BOARD_RESULT="move failed (HTTP $HTTP)"
  elif [ -z "$WORKFLOW_ID" ]; then
    BOARD_RESULT="no workflow lists project #${PROJECT_ID} — skipped"
  else
    BOARD_RESULT="no '${DONE_NAME}' (or fallback) stage in workflow #${WORKFLOW_ID} — skipped"
  fi
  rm -f "$STAGE_TSV"
fi
```

Board failure is **non-fatal** (most likely a permissions or board-config
mismatch that retrying will not fix) — record the state and continue.

### Step 14.2 — Mark complete

```bash
# curl exits 0 on an HTTP error, so the pre-1.3.0 `curl … && BOARD_RESULT=completed`
# reported every 401 / 403 / 404 as "completed". Judge the status code instead.
HTTP=$(curl -sS -u "$AUTH" -X PUT -H "Accept: application/json" \
  -o /tmp/tws_complete.json -w '%{http_code}' \
  "${BASE}/projects/api/v3/tasks/${PRIMARY_TASK_ID}/complete.json")
if [ "$HTTP" -ge 200 ] 2>/dev/null && [ "$HTTP" -lt 300 ]; then
  BOARD_RESULT="completed"
else
  BOARD_RESULT="complete failed (HTTP $HTTP)"
  echo "⚠ ${BOARD_RESULT}: $(head -c 300 /tmp/tws_complete.json 2>/dev/null)" >&2
fi
```

`leave` → `BOARD_RESULT="left as created"`, no call.

---

## Step 15 — Final report

### Step 15.1 — Run duration + history

```bash
RUN_END_EPOCH=$(date -u +%s); RUN_END_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
RUN_SECS=$(( RUN_END_EPOCH - RUN_START_EPOCH ))
DURATION_FORMAT=$(jq -r '.session_skill.timing.duration_format // "human"' "$CONFIG_FILE")
case "$DURATION_FORMAT" in
  compact) RUN_HUMAN=$(printf '%d:%02d' $((RUN_SECS/60)) $((RUN_SECS%60))) ;;
  *)       RUN_HUMAN="$((RUN_SECS/60)) min $((RUN_SECS%60)) s" ;;
esac

if [ "$(jq -r '.session_skill.timing.report_run_duration | if . == null then true else . end' "$CONFIG_FILE")" = "true" ]; then
  HIST="${CONFIG_DIR}/runs.tsv"; mkdir -p "$(dirname "$HIST")"
  [ -f "$HIST" ] || printf 'started_at\tended_at\tduration_s\tsource\ttask_id\tlogged_min\ttitle\n' > "$HIST"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$RUN_START_ISO" "$RUN_END_ISO" "$RUN_SECS" "teamwork-tasks-from-session" \
    "${PRIMARY_TASK_ID:-}" "${DURATION_MIN:-0}" "$(printf %s "$PRIMARY_NAME" | tr '\t\n' '  ')" >> "$HIST"
fi
```

### Step 15.2 — Render

```markdown
## ✅ Task z session vytvorený

**Task:** <PRIMARY_NAME> (#<PRIMARY_TASK_ID>) — <PRIMARY_TASK_URL>
**Cieľ:** <PROJECT_NAME> › <TASKLIST_NAME>  <(+ "subtask of #<PARENT_TASK_ID>")>
**Odhad:** <EST> min · **Priradené:** <name / nepriradené>

### ⏱ Zalogovaný čas
- <DURATION_MIN> min od <LOG_TIME> (<LOG_DATE>) — <START_SOURCE>
- <OVERLAP_NOTE, if any> · billable: <yes/no> · ✅ zalogované / ⏭ nelogované / ⚠ zlyhalo

### Subtasky
- ✅ [BE] <name> (#<id>) — <est> min — <assignee>
- ❌ [QA] <name> — <reason>

### Board
- <BOARD_RESULT>

### Otvorené
- [OTVORENÉ] <question> — ponechané v <section>

### Beh skillu
- Trvanie: <RUN_HUMAN> (invokácia → task vytvorený + čas zalogovaný)
```

---

## Hard boundaries (what this skill **never** does)

- Never runs `git commit`, `git add`, `git push`, or any git write — it only
  *reads* the commits the session already produced
- Never logs time without an explicit Step 10 confirmation
- Never writes a time log that overlaps an existing entry (the overlap clamp in
  Step 9 is unconditional when `avoid_overlap == true`)
- Never invents time when the computed duration is ~0 — it asks instead
- Never silently overwrites an estimate (the estimate is on a *new* task; there
  is nothing to overwrite, and the methodology number is always shown)
- Never writes the estimate into the task **title** or **description** — the
  minutes go to the `estimatedMinutes` field only (Step 11 / Step 12). The
  preview (Step 10) and the final report (Step 15) may show it; the task body
  may not.
- Never moves the board or completes the task without asking (default
  `board.after_create == ask`)
- Never edits an existing task's description. This skill only **creates** tasks;
  it never PATCHes a description it did not write. A Teamwork description can
  carry inline screenshots as Markdown image links
  (`![image.png](https://tw-inlineimages.s3-accelerate.amazonaws.com/...)`) that
  exist nowhere else in the task — rewriting a description deletes them. If a
  future version ever needs to touch an existing description, it must carry the
  original text, its image links and its attachment references forward **byte
  for byte**, and append only.
- Never claims a cross-cutting requirement (menu entry, inbound link,
  authorization, pagination, …) that the diff or the conversation does not
  prove — an uncovered one is listed as *nepokryté v tejto session*, and no
  acceptance box is ever pre-ticked
- Never claims a framework version or idiom the lock files and the diff do not
  show, and never turns `framework` into an acceptance criterion — it is a
  technical-plan line only (Step 6.2b)
- Never asks `workflows.json` without a project id, and never moves a task into
  a workflow that does not list the task's project
- Never sends anything to a customer or to Teamwork Desk
- Never echoes the API token

---

## Failure modes & recovery

| Failure | Behaviour |
|---|---|
| No URL passed | Step 5 asks for the target |
| URL unparseable | Re-ask once, then stop |
| `me.json` 401 | Re-prompt the Projects token (Step 2 first-run flow) |
| `me.json` other error | Warn; "assign to me" + last-timelog fallback degrade — keep going |
| No SessionStart hook record | Fall back to last timelog → transcript → ask |
| Start detected in the future | Discard, fall through to the next detector |
| Computed duration ~0 | Offer skip-log or manual minutes in Step 10 (never invent) |
| Long session (> warn threshold) | Show a warning; still log after confirmation |
| Project/tasklist/task 403/404 | Stop with the failing URL printed (a completed tasklist answers 404 too) |
| Parent task has no project id in `.task.tasklist.meta` / `included.tasklists` | `⚠` warning; Step 14.1 board move is skipped, never guessed |
| `time.json` / `people.json` / `me.json` non-200 | `⚠` line naming the endpoint and the fallback; the run continues |
| No workflow lists the project, or no done stage in it | Board move skipped with the reason in the report |
| Email resolves to 0 people | AskUserQuestion (retry / unassigned / cancel) |
| Email resolves to ≥2 people | AskUserQuestion to pick the right person |
| Primary task POST returns no id | Idempotency probe (search by name, last 120 s) before failing |
| Subtask POST non-2xx | Log `❌`, continue with the rest |
| Time-log POST non-2xx | Report; do not retry blindly; task already exists |
| Board move / complete non-2xx | Non-fatal; record the state and continue |
| `jq` parse error on a response | Re-parse via Python; never panic-retry a POST |

---

## Persistent learning

On each successful run the skill keeps the shared config populated so later runs
need no probes:

- `session_skill.task_create_estimate_field` — `"estimatedMinutes"` (the v3
  write-field quirk; default already correct)
- `session_skill.session_start.*` — detection order, ignored sources, today
  constraint, warn threshold
- `session_skill.timing.*` — run-duration reporting on by default

A historical TSV of every run lives at
`~/.claude/plugins/data/teamwork-task-wamesk/runs.tsv` (`started_at`,
`ended_at`, `duration_s`, `source`, `task_id`, `logged_min`, `title`). All
config writes are atomic (`jq` + `mv` + `chmod 600`).

---

## The SessionStart hook (how the start is recorded)

This plugin ships `hooks/hooks.json` + `hooks/record-session-start.sh`, wired to
the **SessionStart** event. On every session start the hook appends one row to:

```
~/.claude/plugins/data/teamwork-task-wamesk/sessions/starts.tsv
epoch <TAB> iso <TAB> session_id <TAB> source <TAB> cwd <TAB> transcript
```

`source` is the Claude Code SessionStart source (`startup` / `resume` / `clear` /
`compact`); Step 3.1 ignores `compact` rows (mid-session, not a real start). The
hook writes **no** stdout (no context injection) and always exits 0, so it can
never disrupt session startup. It is the only deterministic way for the skill to
know when the session began — which is why a session that was already running
*before* the plugin was installed has no record, and the skill falls back to the
last-timelog / transcript / ask chain instead.

Because hooks load at session start, installing the plugin only starts recording
from the **next** Claude Code session (after a restart).

---

## Task record rules

> Block version `wame-task-record-v1`. Shared **verbatim** across the plugins that write a Teamwork
> task — `teamwork-task-analyze`, `teamwork-tasks-from-desk`, `teamwork-tasks-from-session` and
> `teamwork-tasks-from-dnr`. Change it in all of them or in none.

### The estimate lives in the estimate field, and nowhere else

Never write minutes or hours into a task's **title** or **description**. Not in the preamble, not
inside the technical plan, not as a footer line under it.

The reason is maintenance, not taste. An estimate gets revised — after the first hour of work, after
a clarifying answer comes back, after the task is split into subtasks. A number that also sits in
prose has to be found and changed in every copy it was written to, and the copy somebody misses is
the one the next reader believes. One field, one number, nothing to reconcile.

This binds every surface that writes a task:

- the description body, including any `**Odhad:** … min` or `**Estimate:** … min` line
- the task title, including a `(120 min)` or `· 2h` suffix
- the description column of a generated import file
- a subtask's title and description, on the same terms as the parent

Where the estimate belongs instead: the API estimate field — `estimateMinutes` on a v3 read,
`estimatedMinutes` on a v3 create, `estimated-minutes` on the classic v1 update.

Where it is still fine to show: the terminal preview, the confirmation gate, the final report, and
any companion document that is not the task itself — a Desk internal note, a Markdown plan sitting
next to an XLSX. Those are read once and thrown away. The task record is not.

### Never lose what the reporter wrote

When this skill rewrites an **existing** task description, everything already there survives
**verbatim** at the top, above the first `---`.

- **Inline images.** A screenshot pasted into a Teamwork description is ordinary Markdown:
  `![image.png](https://tw-inlineimages.s3-accelerate.amazonaws.com/…)`. It is **not** a separate
  attachment, and Teamwork shows it **nowhere else** — `GET /projects/api/v3/tasks/{id}/files.json`
  returns nothing for it. Dropping that link deletes the screenshot from the task. This is not
  hypothetical: one run stripped the image links out of 18 descriptions on the assumption that
  Teamwork rendered them separately, and destroyed 25 screenshots. They came back only because the
  original text happened to still be in a scratch file.
- **The reporter's own wording, spelling and punctuation.** Do not add diacritics, do not fix
  grammar, do not translate, do not tighten, do not re-order. A bug report is the record of what
  somebody saw and how they described it. A tidied version is no longer that record, and the tester
  cannot recognise their own report in it.
- **Links, lists, line breaks, and any HTML that is already there.** Pass the block through
  untouched.

Before writing, read the current description. After composing the new one, check that the old text
still occurs inside it character for character. When it does not, you are about to delete somebody's
work — stop and ask the user instead of writing.

Attachments and comments are separate records and this skill never touches them. If a change would
need one removed, that is a question for the user, not a step in the plan.

---

## WAME estimate methodology

> Block version `wame-estimate-v2`. Shared **verbatim** across the plugins
> `teamwork-task-analyze`, `teamwork-tasks-from-dnr`, `teamwork-tasks-from-desk`,
> `teamwork-tasks-from-session` and `dnr-business`. Change it in all five or in
> none — a per-plugin variant is how two skills start quoting different numbers
> for the same task.

**Estimate one number, directly.** Do not produce a "traditional" estimate and
then multiply it by a speedup and a buffer. Two percentages stacked on a guess
open a band almost twice as wide as the guess itself, and in a negotiation the
widest end of that band always wins. Name the minutes the work takes and defend
that number.

**Who does the work.** A senior engineer who already knows this codebase,
directing Claude Code. Claude Code writes the implementation and the tests; the
engineer decides, reviews and runs the suite. There is no separate QA pass and
no handover to a second person.

**What the number covers**

- Reading the relevant code and reproducing the reported behaviour
- The implementation itself
- Writing or extending the test, and running the affected tests
- Self-review and the fixes it produces
- One round of review feedback

**What the number never covers** — estimate each of these as its own task instead
of folding it in

- Deployment, running the migration on production, fixing production data
- Talking to the client or the PO, and waiting for the answer
- Any work that sits behind an unanswered `[OTVORENÉ]` question
- Anything the task itself declares out of scope

**Shape of the number**

- A multiple of 15 minutes. Never below 15.
- Above 240 minutes: propose a split into 2–6 atomic subtasks. That threshold is
  `propose_split_threshold_minutes` and it is the real ceiling in daily use.
- 480 minutes is a hard cap. Work that will not fit under it is not a task yet.

**Anchors.** These are finished outcomes, not categories of feeling. Pick the
closest line and move by at most one 15-minute step. If the number you want is
more than one step away from every anchor, write down in the reasoning what makes
this case different — that sentence is what a reviewer checks.

| Finished work | Minutes |
|---|---|
| Text, label, translation key or config value, plus the test that guards it | 15 |
| One field, filter or validation rule on one screen, plus a test | 30 |
| Bug with a stack trace or a one-line repro: fix plus regression test | 60 |
| Vue/React component wired to an API that already exists, plus a test | 90 |
| Bug that reproduces but spans 2–3 layers: fix plus tests | 120 |
| One CRUD endpoint or one screen end to end, plus tests | 120 |
| Bug with no repro yet: investigate, then fix | 180 |
| Schema migration with a data backfill and a copy-back assertion | 180 |
| New module in `wamesk/*` (model, migration, Nova screen, policy, tests) | 300 |

**Uncertainty is an open question, not a surcharge.** When you cannot size the
work, you have found something the task does not say yet. Write that question
into the task, estimate the investigation that answers it, and state in the
reasoning what the fix costs under each likely answer. A number with a written
assumption survives review. A number padded for "unknown unknowns" does not, and
it hides the question that was worth asking.

**Do not pad a task because it is labelled TBD**, and do not shrink a real
multi-layer bug so the list looks cheap. Both errors cost the same trust.

**Why this replaced the old rule.** Hand-written estimates used to run about
twice the real cost, which lost us work we should have won. The first fix was a
30–50 % speedup factor with a 15–30 % buffer on top — but that chain put the
padding straight back while sounding rigorous, and it produced a 0.58×–0.91×
band on every single task. The anchors above carry the same judgement as one
number. The measured feedback loop is the `teamwork-tasks-from-session` plugin,
which shows the methodology estimate and the real logged session time side by
side. When those two drift apart on the same kind of work, change the anchors
here — never re-introduce a buffer percentage.

---

## Output style

Default to Slovak (`sk`) for the description sections, questions, and the
time-log description unless `--language=en` / `default_language=en` says
otherwise. Section headings use the labels from `session_skill.sections` so a
project that prefers English can configure them centrally. Code identifiers,
file paths, commit hashes, and brand names stay in their original form
regardless of language. Keep summaries compact — numbered lists for plans,
checkbox lists for AC.
