---
name: teamwork-tasks-from-session
description: "Use when the user has been solving something directly in a Claude Code session (often before any task existed) and asks to 'vytvor task z tejto session', 'vytvor teamwork task zo session', 'zaloguj túto session ako task', 'sprav task z toho čo sme robili', 'z tejto session vytvor task a zaloguj čas', 'create a task from this session', 'log this session as a task', or invokes '/teamwork-tasks-from-session'. Reconstructs what the session accomplished — git commits + working-tree diff made since the session started, changed files, repo shape, and the live conversation context — and drafts a Teamwork.com Projects task in the canonical WAME format ([preamble] → HR → Akceptačné kritériá → HR → Cieľ → HR → Technický popis, the same Plan-Mode technical write-up produced by teamwork-task-analyze), with optional 2–6 atomic subtasks and a WAME senior-engineer-with-Claude-Code estimate. Detects the session start from a bundled SessionStart hook (fallbacks: end of today's last timelog → newest session transcript timestamp → ask) and logs the real session duration back to Teamwork as one sequential, non-overlapping, 5-minute-aligned entry — always shown as an editable proposal first, clamped so it never overlaps an existing timelog. If no Teamwork URL is passed it asks where to file the work; a project/tasklist URL creates a new main task, a single-task URL files the work as a subtask of that task. Asks via AskUserQuestion which Teamwork email to assign the task to (you by default, unassigned, or a custom email resolved via people.json). Everything is shown in a full preview + confirmation gate before any write; after creation the skill asks what to do with the board (leave / move In progress → Internal testing / complete). Reuses the shared API token config with the rest of the Teamwork plugin family. Never runs git, never logs time without confirmation, never writes an overlapping time log, never silently overwrites an estimate."
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
  the done stage; `complete` = mark the task complete.
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
on every invocation — `//=` is idempotent and never clobbers a user's value.

```bash
TMP=$(mktemp)
jq '
  .default_language                                   //= "sk"
| .time_rounding_minutes                              //= 5
| .round_threshold_minutes                            //= 4
| .min_log_minutes                                    //= 1
| .time_cursor_strategy                               //= "last_teamwork_timelog"
| .include_commit_hash_in_log_description             //= true
| .is_billable_by_default                             //= true
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
| .session_skill.estimate.methodology                 //= "wame_senior_claude_code"
| .session_skill.estimate.set_if_missing              //= true
| .session_skill.estimate.buffer_pct_min              //= 15
| .session_skill.estimate.buffer_pct_max              //= 30
| .session_skill.estimate.speedup_pct_min             //= 30
| .session_skill.estimate.speedup_pct_max             //= 50
| .session_skill.estimate.step_minutes                //= 15
| .session_skill.estimate.max_task_minutes            //= 480
| .session_skill.subtasks                             //= {}
| .session_skill.subtasks.enabled                     //= true
| .session_skill.subtasks.propose_split_threshold_minutes //= 240
| .session_skill.subtasks.min_split_subtasks          //= 2
| .session_skill.subtasks.max_split_subtasks          //= 6
| .session_skill.subtasks.role_prefixes               //= ["BE","FE","QA","Migration","DevOps"]
| .session_skill.assignee                             //= {}
| .session_skill.assignee.default_to_me               //= true
| .session_skill.assignee.ask                         //= true
| .session_skill.assignee.allow_empty                 //= true
| .session_skill.clarifying_questions                 //= {}
| .session_skill.clarifying_questions.max_per_run     //= 6
| .session_skill.clarifying_questions.fold_into_description //= true
| .session_skill.clarifying_questions.leave_unresolved_as_open_marker //= "[OTVORENÉ]"
| .session_skill.session_start                        //= {}
| .session_skill.session_start.detection_order        //= ["hook","last_timelog","transcript","ask"]
| .session_skill.session_start.hook_enabled           //= true
| .session_skill.session_start.sessions_log_relpath   //= "sessions/starts.tsv"
| .session_skill.session_start.constrain_today        //= true
| .session_skill.session_start.ignore_sources         //= ["compact"]
| .session_skill.session_start.max_session_hours_warn //= 6
| .session_skill.time_log                             //= {}
| .session_skill.time_log.enabled                     //= true
| .session_skill.time_log.log_target                  //= "primary_task"
| .session_skill.time_log.avoid_overlap               //= true
| .session_skill.time_log.confirm_before_log          //= true
| .session_skill.board                                //= {}
| .session_skill.board.after_create                   //= "ask"
| .session_skill.board.in_progress_stage              //= "In progress"
| .session_skill.board.done_stage                     //= "Internal testing"
| .session_skill.board.done_stage_fallbacks           //= ["Testing"]
| .session_skill.board.match_mode                     //= "case_insensitive"
| .session_skill.link_session                         //= {}
| .session_skill.link_session.include_commits         //= true
| .session_skill.link_session.include_branch          //= true
| .session_skill.link_session.max_commits_listed      //= 20
| .session_skill.task_create_estimate_field           //= "estimatedMinutes"
| .session_skill.timing                               //= {}
| .session_skill.timing.report_run_duration           //= true
| .session_skill.timing.duration_format               //= "human"
' "$CONFIG_FILE" > "$TMP" && mv "$TMP" "$CONFIG_FILE" && chmod 600 "$CONFIG_FILE"
```

CLI flags override `.session_skill.*` and the time keys for the duration of this
run only.

Resolve the language once:

```bash
LANG=$(jq -r '.default_language // "sk"' "$CONFIG_FILE")   # CLI --language wins
ACC_LABEL=$(jq -r --arg l "$LANG" '.session_skill.sections["acceptance_label_"+$l] // .session_skill.sections.acceptance_label_sk' "$CONFIG_FILE")
GOAL_LABEL=$(jq -r --arg l "$LANG" '.session_skill.sections["goal_label_"+$l]       // .session_skill.sections.goal_label_sk' "$CONFIG_FILE")
TECH_LABEL=$(jq -r --arg l "$LANG" '.session_skill.sections["tech_label_"+$l]       // .session_skill.sections.tech_label_sk' "$CONFIG_FILE")
SRC_LABEL=$(jq -r --arg l "$LANG" '.session_skill.sections["source_label_"+$l]      // .session_skill.sections.source_label_sk' "$CONFIG_FILE")
```

### Step 2.6 — Resolve the current user (cached for the whole run)

Needed both for the "last timelog" session-start fallback (Step 3) and for the
"assign to me" default (Step 7).

```bash
ME_JSON=$(curl -sS -u "$AUTH" -H "Accept: application/json" "${BASE}/me.json")
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
CONSTRAIN_TODAY=$(jq -r '.session_skill.session_start.constrain_today // true' "$CONFIG_FILE")
SESS_TSV="${CONFIG_DIR}/$(jq -r '.session_skill.session_start.sessions_log_relpath // "sessions/starts.tsv"' "$CONFIG_FILE")"

START_EPOCH=""
START_SOURCE=""
```

A cross-platform ISO-8601 → epoch parser (identical to the one in
`teamwork-task` Step 5.5), used by several branches below:

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
if [ -z "$START_EPOCH" ] && [ -n "$USER_ID" ]; then
  RESP=$(curl -sS -u "$AUTH" -H "Accept: application/json" \
    "${BASE}/projects/api/v3/time.json?assignedToUserIds=${USER_ID}&pageSize=1&orderBy=date&orderMode=desc&startDate=${TODAY}")
  LAST_LOGGED=$(jq -r '.timelogs[0].timeLogged // empty' <<<"$RESP")
  LAST_MIN=$(   jq -r '.timelogs[0].minutes    // 0'     <<<"$RESP")
  if [ -n "$LAST_LOGGED" ]; then
    LAST_TS=$(parse_iso "$LAST_LOGGED")
    if [ -n "$LAST_TS" ]; then
      CAND=$(( LAST_TS + LAST_MIN * 60 ))
      if [ "$CAND" -le "$NOW_EPOCH" ]; then
        START_EPOCH="$CAND"; START_SOURCE="end of today's last timelog"
      fi
    fi
  fi
fi
```

`LAST_LOG_END` (this `CAND`, when present) is remembered for the overlap clamp
in Step 9 even when the hook record won the detection.

### Step 3.3 — (c) Newest session transcript

Best-effort: Claude Code stores per-session transcripts as `*.jsonl` under
`~/.claude/projects/<encoded-cwd>/`. The first entry's `timestamp` is the
session start.

```bash
if [ -z "$START_EPOCH" ]; then
  ENC=$(printf '%s' "$PWD_NOW" | sed 's#[/._]#-#g')
  PROJ_DIR="$HOME/.claude/projects/$ENC"
  if [ -d "$PROJ_DIR" ]; then
    NEWEST=$(ls -t "$PROJ_DIR"/*.jsonl 2>/dev/null | head -1)
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
PROJECT_NAME=$(curl -sS -u "$AUTH" "${BASE}/projects/api/v3/projects/${PROJECT_ID}.json" | jq -r '.project.name // ""')
TLS=$(curl -sS -u "$AUTH" "${BASE}/projects/api/v3/projects/${PROJECT_ID}/tasklists.json?pageSize=100")
```

- Exactly one tasklist → use it without asking.
- Multiple → **AskUserQuestion** (label = tasklist name, description = task
  count). Cap at 12 visible; offer a "More…" free-form for longer lists.

Set `TASKLIST_ID`, `TASKLIST_NAME`. `TARGET_MODE="main_in_tasklist"`.

### Step 5.3 — Tasklist URL (`URL_KIND=tasklist`)

```bash
TASKLIST_ID="$ENTITY_ID"
TL_JSON=$(curl -sS -u "$AUTH" "${BASE}/projects/api/v3/tasklists/${TASKLIST_ID}.json")
TASKLIST_NAME=$(jq -r '.tasklist.name // ""'      <<<"$TL_JSON")
PROJECT_ID=$(   jq -r '.tasklist.projectId // .tasklist.project.id // empty' <<<"$TL_JSON")
PROJECT_NAME=$( jq -r '.tasklist.project.name // ""' <<<"$TL_JSON")
TARGET_MODE="main_in_tasklist"
```

### Step 5.4 — Task URL (`URL_KIND=task`) → subtask mode

A task URL means **"file the session work as a subtask of that task"**.

```bash
PARENT_TASK_ID="$ENTITY_ID"
PT_JSON=$(curl -sS -u "$AUTH" "${BASE}/projects/api/v3/tasks/${PARENT_TASK_ID}.json?include=tasklists,projects")
PARENT_TASK_NAME=$(jq -r '.task.name // ""'        <<<"$PT_JSON")
TASKLIST_ID=$(     jq -r '.task.tasklistId // empty' <<<"$PT_JSON")
PROJECT_ID=$(      jq -r '.task.projectId  // empty' <<<"$PT_JSON")
TARGET_MODE="subtask_of_parent"
```

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

```
[optional preamble — only if there is genuinely useful free-text context that
does not fit the structured sections; otherwise omit entirely]

---

## {ACC_LABEL}
- [ ] AC 1 — atomic, testable, written from the user's perspective
- [ ] AC 2 — …

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

### Step 6.3 — Subtasks (optional)

Propose subtasks **only** when **all** are true:

1. `--no-subtasks` is not set and `subtasks.enabled == true`.
2. The total estimate exceeds `subtasks.propose_split_threshold_minutes` (240).
3. The work has natural cut points (different layers / components / migration vs
   feature).

Each subtask: a `[BE]/[FE]/[QA]/[Migration]/[DevOps]` prefix + business name, its
own canonical description (no preamble, no `### {SRC_LABEL}` — only the primary
task carries the source block), and its own estimate. Count 2–6. **Never
force-split** small sessions.

### Step 6.4 — Estimate

Use the **WAME methodology** (full text at the bottom of this document): start
from a senior-engineer estimate, apply 30–50 % Claude-Code speedup, add 15–30 %
buffer, round to `estimate.step_minutes` (15), cap at `estimate.max_task_minutes`
(480). When there are subtasks, the main estimate is the **sum** of subtask
estimates.

The estimate is the *methodology* number (what the work "should" cost); it is
**independent** of the logged session time (what it actually took this run).
Both appear in the preview — that contrast is useful, not a bug.

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
RESP=$(curl -sS -u "$AUTH" "${BASE}/projects/api/v3/people.json?searchTerm=${EMAIL_ENCODED}&pageSize=10")
MATCHES=$(jq -r '[ (.people // [])[] | select(((.email // .emailAddress // "")|ascii_downcase) == ("'"$EMAIL"'"|ascii_downcase)) ]' <<<"$RESP")
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
AVOID_OVERLAP=$(jq -r '.session_skill.time_log.avoid_overlap // true' "$CONFIG_FILE")

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

### ⏱ Čas na zalogovanie
- Štart:   <LOG_TIME> (<START_SOURCE>)
- Koniec:  <now HH:MM>
- Trvanie: **<DURATION_MIN> min**  (raw <RAW_MIN> min)
- <OVERLAP_NOTE, if any>
- Loguje sa na: <primary task title>
- Billable: <yes/no>
- <"⚠ dlhá session — over čas" when over the warn threshold>

### Po vytvorení (board)
- <"Spýtam sa" when board.after_create == ask, else the configured action>
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

```bash
EST_FIELD=$(jq -r '.session_skill.task_create_estimate_field // "estimatedMinutes"' "$CONFIG_FILE")

DESC_PATH="$(mktemp)"; printf '%s' "$PRIMARY_DESC" > "$DESC_PATH"
PAYLOAD_PATH="$(mktemp)"
python3 - "$DESC_PATH" "$PAYLOAD_PATH" <<PY
import json, sys
desc = open(sys.argv[1]).read()
payload = {"task": {
    "name":           ${PRIMARY_NAME@Q},
    "description":    desc,
    "${EST_FIELD}":   ${PRIMARY_EST},
}}
aid = ${PRIMARY_ASSIGNEE_ID:-0}
if aid: payload["task"]["assignees"] = {"userIds": [aid]}
pid = ${PARENT_TASK_ID:-0}
if pid: payload["task"]["parentTaskId"] = pid
json.dump(payload, open(sys.argv[2], "w"), ensure_ascii=False)
PY

HTTP=$(curl -sS -u "$AUTH" -H "Content-Type: application/json" -H "Accept: application/json" \
  -X POST -d @"$PAYLOAD_PATH" -o /tmp/tws_main.json -w '%{http_code}' \
  "${BASE}/projects/api/v3/tasklists/${TASKLIST_ID}/tasks.json")

PRIMARY_TASK_ID=$(python3 -c "import json;d=json.load(open('/tmp/tws_main.json'));t=d.get('task',d);print(t.get('id') or '')")

if [ -z "$PRIMARY_TASK_ID" ]; then
  # Idempotency probe before giving up / retrying.
  NAME_ENC=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$PRIMARY_NAME")
  PRIMARY_TASK_ID=$(curl -sS -u "$AUTH" \
    "${BASE}/projects/api/v3/tasklists/${TASKLIST_ID}/tasks.json?searchTerm=${NAME_ENC}&pageSize=5" \
    | python3 -c "
import json,sys,datetime
d=json.load(sys.stdin); now=datetime.datetime.utcnow()
for t in d.get('tasks',[]):
    if t.get('name')==${PRIMARY_NAME@Q}:
        ts=(t.get('createdAt') or t.get('dateCreated') or '').rstrip('Z')
        try:
            if (now-datetime.datetime.strptime(ts,'%Y-%m-%dT%H:%M:%S')).total_seconds()<120:
                print(t['id']); break
        except Exception: pass")
fi

if [ -z "$PRIMARY_TASK_ID" ]; then
  echo "❌ Primary task creation failed (HTTP ${HTTP}):"; head -c 1000 /tmp/tws_main.json; exit 1
fi
PRIMARY_TASK_URL="${BASE}/app/tasks/${PRIMARY_TASK_ID}"
echo "✅ Vytvorený task: ${PRIMARY_NAME} (#${PRIMARY_TASK_ID})"
rm -f "$DESC_PATH" "$PAYLOAD_PATH"
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

SUB_DESC_PATH="$(mktemp)"; printf '%s' "$SUB_DESC" > "$SUB_DESC_PATH"
SUB_PAYLOAD_PATH="$(mktemp)"
python3 - "$SUB_DESC_PATH" "$SUB_PAYLOAD_PATH" <<PY
import json, sys
desc = open(sys.argv[1]).read()
payload = {"task": {
    "name":          ${SUB_NAME@Q},
    "description":   desc,
    "${EST_FIELD}":  ${SUB_EST},
    "parentTaskId":  ${PRIMARY_TASK_ID},
}}
uid = ${SUB_ASSIGNEE_ID:-0}
if uid: payload["task"]["assignees"] = {"userIds": [uid]}
json.dump(payload, open(sys.argv[2], "w"), ensure_ascii=False)
PY

SUB_RESP=$(curl -sS -u "$AUTH" -H "Content-Type: application/json" \
  -X POST -d @"$SUB_PAYLOAD_PATH" \
  "${BASE}/projects/api/v3/tasklists/${TASKLIST_ID}/tasks.json")
SUB_ID=$(python3 -c "import json,sys;d=json.loads(${SUB_RESP@Q});t=d.get('task',d);print(t.get('id') or '')")
if [ -n "$SUB_ID" ]; then SUBTASK_IDS+=("$SUB_ID"); echo "✅ Subtask: ${SUB_NAME} (#${SUB_ID})";
else SUBTASK_FAILURES+=("${SUB_NAME}"); echo "❌ Subtask zlyhal: ${SUB_NAME}"; fi
rm -f "$SUB_DESC_PATH" "$SUB_PAYLOAD_PATH"
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
BILLABLE=$(jq -r '.is_billable_by_default // true' "$CONFIG_FILE")
INCL_HASH=$(jq -r '.include_commit_hash_in_log_description // true' "$CONFIG_FILE")

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

When `ask`, run one **AskUserQuestion**:

> "Práca je hotová — čo spraviť s taskom na boarde?"
>
> - **Nechať tak** — no board change (default)
> - **Presunúť do „Internal testing"** — move to the done stage (ready for QA)
> - **Označiť ako dokončený** — mark the task complete

### Step 14.1 — Move to the done stage

Resolve the project's workflow + done stage by name (case-insensitive, with
fallbacks), then POST the move — same mechanism as `teamwork-task`:

```bash
WF_RESP=$(curl -sS -u "$AUTH" -H "Accept: application/json" \
  "${BASE}/projects/api/v3/workflows.json?projectIds=${PROJECT_ID}&include=stages")
WORKFLOW_ID=$(jq -r '.workflows[0].id // empty' <<<"$WF_RESP")

STAGE_TSV="/tmp/tws_stages_${PROJECT_ID}.tsv"
jq -r '
  if (.included.stages|type)=="object" then .included.stages|to_entries[]|[(.value.name//""),(.key//(.value.id|tostring))]
  elif (.included.stages|type)=="array" then .included.stages[]|[(.name//""),(.id|tostring)]
  else empty end | "\(.[0]|ascii_downcase)\t\(.[1])"' <<<"$WF_RESP" > "$STAGE_TSV"

lookup_stage() { awk -F '\t' -v n="$(printf '%s' "$1"|tr '[:upper:]' '[:lower:]')" '$1==n{print $2;exit}' "$STAGE_TSV"; }

DONE_NAME=$(jq -r '.session_skill.board.done_stage // "Internal testing"' "$CONFIG_FILE")
DONE_STAGE_ID=$(lookup_stage "$DONE_NAME"); DONE_RESOLVED="$DONE_NAME"
if [ -z "$DONE_STAGE_ID" ]; then
  while IFS= read -r FB; do
    [ -z "$FB" ] && continue
    C=$(lookup_stage "$FB"); [ -n "$C" ] && { DONE_STAGE_ID="$C"; DONE_RESOLVED="$FB"; break; }
  done < <(jq -r '.session_skill.board.done_stage_fallbacks[]?' "$CONFIG_FILE")
fi

if [ -n "$WORKFLOW_ID" ] && [ -n "$DONE_STAGE_ID" ]; then
  HTTP=$(curl -sS -o /dev/null -w '%{http_code}' -u "$AUTH" -H "Content-Type: application/json" \
    -X POST -d "{\"taskIds\":[${PRIMARY_TASK_ID}]}" \
    "${BASE}/projects/api/v3/workflows/${WORKFLOW_ID}/stages/${DONE_STAGE_ID}/tasks.json")
  [ "$HTTP" -ge 200 ] && [ "$HTTP" -lt 300 ] && BOARD_RESULT="moved → ${DONE_RESOLVED}" || BOARD_RESULT="move failed (HTTP $HTTP)"
else
  BOARD_RESULT="no workflow/done stage on project — skipped"
fi
```

Board failure is **non-fatal** (most likely a permissions or board-config
mismatch that retrying will not fix) — record the state and continue.

### Step 14.2 — Mark complete

```bash
curl -sS -u "$AUTH" -X PUT -H "Accept: application/json" \
  "${BASE}/projects/api/v3/tasks/${PRIMARY_TASK_ID}/complete.json" >/dev/null \
  && BOARD_RESULT="completed" || BOARD_RESULT="complete failed"
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

if [ "$(jq -r '.session_skill.timing.report_run_duration // true' "$CONFIG_FILE")" = "true" ]; then
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
- Never moves the board or completes the task without asking (default
  `board.after_create == ask`)
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
| Project/tasklist/task 403/404 | Stop with the failing URL printed |
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

## WAME estimate methodology

We estimate as senior engineers using Claude Code as a force multiplier.

Baseline assumptions:
- Engineer is senior in the stack of the current repo
- Claude Code handles boilerplate / scaffolding / repetitive edits
- Test scaffolding (Pest/PHPUnit/Vitest/Playwright) is mostly LLM-generated
- Code review and QA are done by the same engineer (no separate review cycle)

Speedup vs a traditional estimate: ~30–50 % faster — apply that reduction first.

Buffer policy: after the reduction, add 15–30 % buffer for unknown unknowns
(undocumented APIs, hidden coupling), environment friction (failing CI, flaky
local setup), and review feedback that costs more than one cycle.

The final number must be a multiple of 15 minutes, at least 15 minutes for
trivial work, and at most 8 hours (480 min) per single task — bigger work must
be split into subtasks (Step 6.3).

Calibration anchors (sanity check, not a lookup table; minutes, post-speedup,
post-buffer):

| Work type | Estimate |
|---|---|
| Trivial copy / label change | 15 |
| Bug fix with known repro | 30–60 |
| Single-model CRUD endpoint + Pest test | 60–120 |
| New Vue/React component wired to existing API | 60–120 |
| New module in `wamesk/*` (model + migration + controller + tests) | 240–360 |
| DB schema migration with data backfill | 180–300 |
| Bug fix without repro / investigation | 120–360 |

Remember: this methodology number is the task's **estimate**; the **logged**
time is the real session duration from Step 9. They are reported side by side on
purpose.

---

## Output style

Default to Slovak (`sk`) for the description sections, questions, and the
time-log description unless `--language=en` / `default_language=en` says
otherwise. Section headings use the labels from `session_skill.sections` so a
project that prefers English can configure them centrally. Code identifiers,
file paths, commit hashes, and brand names stay in their original form
regardless of language. Keep summaries compact — numbered lists for plans,
checkbox lists for AC.
