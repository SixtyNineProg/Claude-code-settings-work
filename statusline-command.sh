#!/usr/bin/env bash
# Claude Code statusLine command
# Receives JSON context on stdin.
# Fields used:
#   workspace.current_dir | cwd
#   model.display_name
#   context_window.used_tokens / total_tokens / remaining_tokens / *_percentage
# Plus git branch via `git rev-parse --abbrev-ref HEAD` if a repo is present.
# JSON is parsed by statusline-parse.py (no heredoc-in-subshell pitfalls).

set -u

input="$(cat)"
# --- Log incoming payload for producer debugging (rotate manually) ---
logfile="${HOME:-$USERPROFILE}/.claude/statusline-incoming.log"
# Ensure logfile directory exists
mkdir -p "$(dirname "$logfile")" 2>/dev/null || true
# Timestamp in UTC
_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || printf '%s' "$(python -c 'from datetime import datetime; print(datetime.utcnow().isoformat()+"Z")')"; }
printf '%s\n' "---- $(_ts) ----" >> "$logfile"
printf '%s\n' "$input" >> "$logfile"
printf '%s\n' "" >> "$logfile"

# --- Pick a Python interpreter ---
py=""
for cand in python python3 py; do
  if command -v "$cand" >/dev/null 2>&1; then
    py="$cand"
    break
  fi
done
if [ -z "$py" ]; then
  printf 'no-python\n'
  exit 0
fi

# --- Persist stdin to a temp file ---
tmp_json="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/sl-json.$$.txt")"
printf '%s' "$input" > "$tmp_json"

# --- Parse JSON via dedicated Python script ---
# Allow debug by exporting STATUSLINE_DEBUG=1 in the environment when testing.
parsed="$("$py" "$(dirname "$0")/statusline-parse.py" "$tmp_json" 2>/dev/null)"
status=$?
rm -f "$tmp_json"
if [ $status -ne 0 ] || [ -z "$parsed" ]; then
  printf 'parse-failed\n'
  exit 0
fi

# --- Split the four tab-separated fields ---
IFS=$'\t' read -r path model_name ctx_used ctx_total <<<"$parsed"

# --- Git branch (best-effort) ---
branch=""
if [ -n "$path" ] && [ -d "$path" ] && command -v git >/dev/null 2>&1; then
  branch="$(git -C "$path" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null | tr -d '\r\n')"
fi

# --- Format a token count with k/M suffix (1000-based, matching Claude Code UI). ---
# 1_234_567 -> "1.2M", 85_000 -> "85k", 1500 -> "1.5k", 42 -> "42"
fmt_tokens() {
  awk -v n="$1" 'BEGIN {
    if (n == "") { exit }
    if (n < 1000) { printf "%d", n; exit }
    if (n < 1000000) {
      v = n / 1000
      if (v < 10)        printf "%.1fk", v
      else if (v < 100) printf "%.0fk", v
      else              printf "%.0fk", v
      exit
    }
    v = n / 1000000
    printf "%.1fM", v
  }'
}

# Allow a RAW output mode for debugging exact counts when STATUSLINE_RAW=1.
if [ "${STATUSLINE_RAW:-}" = "1" ]; then
  ctx_used_h="$ctx_used"
  ctx_total_h="$ctx_total"
else
  ctx_used_h="$(fmt_tokens "$ctx_used")"
  ctx_total_h="$(fmt_tokens "$ctx_total")"
fi

# Compute percentage (used / total) when both are numeric.
ctx_pct=""
if [ -n "$ctx_used" ] && [ -n "$ctx_total" ] && [ "$ctx_total" -gt 0 ] 2>/dev/null; then
  # Use one decimal place for percent to reduce truncation confusion; keep as integer if you prefer.
  ctx_pct="$(awk -v u="$ctx_used" -v t="$ctx_total" 'BEGIN { printf "%.1f", (u*100)/t }')"
  # If percent is whole (e.g. 27.0), show without decimal for compactness in non-raw mode
  if [[ "$ctx_pct" == *.0 ]]; then
    ctx_pct="${ctx_pct%.0}"
  fi
fi

# --- ANSI colors ---
RESET=$'\033[0m'
CYAN=$'\033[36m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
DIM=$'\033[2m'

# --- Render (two lines: location on line 1, session on line 2) ---
line1=""
if [ -n "$path" ]; then
  line1+="${CYAN}${path}${RESET}"
else
  line1+="${DIM}no-path${RESET}"
fi
if [ -n "$branch" ]; then
  line1+="${DIM} | ${RESET}${GREEN}${branch}${RESET}"
fi

# Context: render the most informative variant available.
#   1) used + total + pct  -> "54k / 200k (27%)"
#   2) used + total        -> "54k / 200k"
#   3) total + pct         -> "200k (27%)"
#   4) pct only            -> "27%"
ctx_seg=""
if [ -n "$ctx_used_h" ] && [ -n "$ctx_total_h" ] && [ -n "$ctx_pct" ]; then
  ctx_seg="${ctx_used_h} / ${ctx_total_h} (${ctx_pct}%)"
elif [ -n "$ctx_used_h" ] && [ -n "$ctx_total_h" ]; then
  ctx_seg="${ctx_used_h} / ${ctx_total_h}"
elif [ -n "$ctx_total_h" ] && [ -n "$ctx_pct" ]; then
  ctx_seg="${ctx_total_h} (${ctx_pct}%)"
elif [ -n "$ctx_pct" ]; then
  ctx_seg="${ctx_pct}%"
fi

line2=""
if [ -n "$model_name" ]; then
  line2+="${YELLOW}${model_name}${RESET}"
fi
if [ -n "$ctx_seg" ]; then
  [ -n "$line2" ] && line2+="${DIM} | ${RESET}"
  line2+="${BLUE}ctx:${ctx_seg}${RESET}"
fi

printf '%s\n' "$line1"
if [ -n "$line2" ]; then
  printf '%s\n' "$line2"
fi
