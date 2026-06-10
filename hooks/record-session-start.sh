#!/usr/bin/env bash
#
# SessionStart hook for the `teamwork-tasks-from-session` plugin.
#
# Records the wall-clock start of every Claude Code session into a shared TSV
# so the /teamwork-tasks-from-session skill can later propose:
#   "log time from when this session started".
#
# Design rules (a SessionStart hook must never disrupt startup):
#   * writes NOTHING to stdout — no context injection into the user's session
#   * always exits 0, even on any internal error
#   * has no hard dependency beyond coreutils (jq / python3 are optional)
#
# Row schema (tab-separated):
#   epoch <TAB> iso <TAB> session_id <TAB> source <TAB> cwd <TAB> transcript
#
# `source` is the Claude Code SessionStart source: startup | resume | clear |
# compact. The skill ignores `compact` rows (mid-session, not a real start).

set -u

DATA_DIR="${HOME}/.claude/plugins/data/teamwork-task-wamesk"
SESS_DIR="${DATA_DIR}/sessions"
TSV="${SESS_DIR}/starts.tsv"

# The hook payload (JSON) arrives on stdin. Tolerate its complete absence.
INPUT="$(cat 2>/dev/null || true)"

# Extract a top-level string field from the JSON payload. Prefer jq, fall back
# to python3, then to an empty string. Never errors out.
extract() {
  local key="$1" val=""
  if command -v jq >/dev/null 2>&1; then
    val="$(printf '%s' "$INPUT" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null)"
  fi
  if [ -z "$val" ] && command -v python3 >/dev/null 2>&1; then
    val="$(printf '%s' "$INPUT" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get(sys.argv[1], "") or "")
except Exception:
    pass
' "$key" 2>/dev/null)"
  fi
  printf '%s' "$val"
}

SESSION_ID="$(extract session_id)"
SOURCE="$(extract source)"
CWD="$(extract cwd)"
TRANSCRIPT="$(extract transcript_path)"

[ -z "$CWD" ] && CWD="${PWD:-$(pwd 2>/dev/null)}"
[ -z "$SOURCE" ] && SOURCE="startup"

EPOCH="$(date -u +%s 2>/dev/null)"
ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
[ -z "$EPOCH" ] && exit 0

mkdir -p "$SESS_DIR" 2>/dev/null || exit 0

if [ ! -f "$TSV" ]; then
  printf 'epoch\tiso\tsession_id\tsource\tcwd\ttranscript\n' > "$TSV" 2>/dev/null || exit 0
  chmod 600 "$TSV" 2>/dev/null || true
fi

# Strip any embedded tabs/newlines from free-text fields so the row stays well
# formed. A single short printf append is atomic on POSIX (well under PIPE_BUF),
# which keeps concurrent sessions from corrupting each other's rows.
san() { printf '%s' "$1" | tr '\t\n' '  '; }

printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$EPOCH" "$ISO" \
  "$(san "$SESSION_ID")" "$(san "$SOURCE")" "$(san "$CWD")" "$(san "$TRANSCRIPT")" \
  >> "$TSV" 2>/dev/null || true

exit 0
