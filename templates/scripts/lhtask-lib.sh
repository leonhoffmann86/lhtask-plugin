#!/usr/bin/env bash
#
# lhtask-lib.sh — shared helpers for the LHTask plan→implement→review hook chain.
# Sourced by lhtask-plan.sh, lhtask-implement.sh, lhtask-review.sh.
#
# Conventions used across the chain:
#   - AUTOPLAN_AGENT=1 in the environment means "this process / its git commits
#     are agent-driven" → the post-commit hook skips, preventing recursion.
#   - The skip convention for TODO.md: items inside <!-- … --> HTML comments, or
#     under a "## 🚧" heading (e.g. "## 🚧 Deferred"), are NOT planned/implemented.

# Repo root (works from a worktree too).
LHTASK_ROOT="$(git rev-parse --show-toplevel)"

# Config defaults, then override from the repo's lhtask.conf if present.
# shellcheck disable=SC2034  # these knobs are consumed by the sourcing stage scripts.
lhtask_load_config() {
  LHTASK_REVIEW_DIRS="src tests"
  LHTASK_TEST_CMD="echo 'no test command configured' && false"
  LHTASK_CONSTITUTION_FILES="AGENTS.md"
  LHTASK_IMPL_BRANCH="autoplan/impl"
  LHTASK_VENV=""
  LHTASK_CODEGRAPH="auto"
  LHTASK_MODEL=""
  LHTASK_REVIEW_AUTONOMOUS="1"
  LHTASK_NOTIFY="0"
  # --- Subagent-team + deterministic-gate block (kept in sync with lhtask.conf) ---
  LHTASK_STACK="auto"            # auto | nextjs | react | node | python | php | go | rust
  LHTASK_GATE_LINT=""            # empty → resolved from the detected stack (or skipped)
  LHTASK_GATE_TYPECHECK=""
  LHTASK_GATE_TEST=""            # empty → falls back to LHTASK_TEST_CMD
  LHTASK_GATE_BUILD=""
  LHTASK_MAX_ITER="3"            # bounded implement↔gate↔review loop (convergence guarantee)
  LHTASK_PHASE_TIMEOUT="600"     # per-phase `claude -p` timeout in seconds (bounds lock hold)
  LHTASK_VISUAL_MAX_DIFF_RATIO="0.02"   # stage 2 (visual reviewer)
  LHTASK_DEV_URL="http://localhost:3000"  # stage 2 (visual reviewer)
  # shellcheck source=/dev/null
  [ -f "$LHTASK_ROOT/lhtask.conf" ] && . "$LHTASK_ROOT/lhtask.conf"
  return 0
}

# Mandatory prompt preamble: every agent reads the project constitution first.
# Generic across projects — the actual conventions live in the constitution files.
lhtask_preamble() {
  local files="${LHTASK_CONSTITUTION_FILES:-AGENTS.md}"
  cat <<EOF
IMPORTANT — first read these project constitution files COMPLETELY and obey their
conventions strictly: ${files}.
(If any of them references further files, e.g. a frontend-specific guide, read those too.)

Core rules that bind every stage of this workflow:
- Make the smallest change that fully solves the item; follow existing patterns.
- Risk tiers (see the constitution / AGENTS.md) are binding. HIGH-RISK work is NEVER
  done autonomously — auth/permissions, payments/billing, DB schema/migrations,
  secrets/env, infrastructure, deletions with broad impact, anything touching
  production/preview. Such items are only NOTED as "needs human approval", never touched.
- Keep new behavior safe-by-default (dry-run / draft-first) where the project applies it.
EOF
}

# Print a file with skipped sections removed: HTML comments, the "## 🚧 …"
# (deferred) section, and the "## 🔎 …" (review-findings) section — neither of
# the latter two is a task the chain should act on.
lhtask_strip_skipped() {
  awk '
    /<!--/ { inc=1 }
    inc { if (/-->/) inc=0; next }
    /^##[[:space:]]/ { if ($0 ~ /🚧/ || $0 ~ /🔎/) { skip=1; next } else { skip=0 } }
    skip { next }
    { print }
  ' "$1"
}

# Reap a stale lock dir (older than $2 minutes) left by a killed run, so a crash
# can never permanently block future runs.
lhtask_reap_stale_lock() {
  local lockdir="$1" minutes="${2:-15}"
  if [ -d "$lockdir" ] && [ -z "$(find "$lockdir" -prune -mmin -"$minutes" 2>/dev/null)" ]; then
    rmdir "$lockdir" 2>/dev/null || true
  fi
}

# True if the chain is globally disabled or this is an agent commit.
lhtask_should_skip() {
  [ -n "${AUTOPLAN_AGENT:-}" ] && return 0
  [ -f "$LHTASK_ROOT/.git/autoplan.disabled" ] && return 0
  return 1
}

# Build a model flag array for headless claude calls (empty if no override).
# Usage: lhtask_model_flags; claude -p ... "${LHTASK_MODEL_FLAGS[@]}"
# shellcheck disable=SC2034  # LHTASK_MODEL_FLAGS is consumed by the caller.
lhtask_model_flags() {
  LHTASK_MODEL_FLAGS=()
  [ -n "${LHTASK_MODEL:-}" ] && LHTASK_MODEL_FLAGS=(--model "$LHTASK_MODEL")
  return 0
}

# Human-visible run log in the repo root (gitignored): TODO.run.log. Unlike the
# per-stage .git/lhtask-*.log files, this is one consolidated, root-level trace you
# can `tail -f`. Reset at the start of each trigger; each stage appends a header
# and tees its agent output into it.
lhtask_runlog_reset() {  # $1 = path to TODO.run.log
  { printf '# LHTask run — %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '# overwritten on each trigger · follow with: tail -f TODO.run.log\n'; } > "$1"
}
lhtask_runlog_stage() {  # $1 = path, $2 = stage label
  printf '\n===== %s — %s =====\n' "$2" "$(date '+%H:%M:%S')" >> "$1"
}
lhtask_runlog_note() {   # $1 = path, $2 = message
  printf '— %s\n' "$2" >> "$1"
}

# ============================================================================
# Subagent-team + deterministic-gate helpers (used by lhtask-implement.sh and
# lhtask-gate.sh). All degrade gracefully: missing tools → skip, not crash.
# ============================================================================

# Detect the project stack from marker files in $1 (default cwd).
lhtask_detect_stack() {
  local d="${1:-.}"
  if [ -f "$d/next.config.js" ] || [ -f "$d/next.config.mjs" ] || [ -f "$d/next.config.ts" ]; then echo nextjs; return; fi
  if [ -f "$d/package.json" ]; then
    if grep -q '"react"' "$d/package.json" 2>/dev/null; then echo react; else echo node; fi; return
  fi
  if [ -f "$d/pyproject.toml" ] || [ -f "$d/setup.py" ] || [ -f "$d/setup.cfg" ]; then echo python; return; fi
  if [ -f "$d/composer.json" ]; then echo php; return; fi
  if [ -f "$d/go.mod" ]; then echo go; return; fi
  if [ -f "$d/Cargo.toml" ]; then echo rust; return; fi
  echo unknown
}

# Resolve a gate command for a check (lint|typecheck|test|build). Echoes a command
# template (may contain the {path} placeholder) or empty (→ the gate skips it).
# Priority: explicit LHTASK_GATE_<CHECK> → (test only) legacy LHTASK_TEST_CMD →
# built-in per-stack default. LHTASK_STACK=auto → detect from marker files.
lhtask_gate_cmd() {
  local check="$1" stack explicit
  case "$check" in
    lint)      explicit="${LHTASK_GATE_LINT:-}";;
    typecheck) explicit="${LHTASK_GATE_TYPECHECK:-}";;
    test)      explicit="${LHTASK_GATE_TEST:-}";;
    build)     explicit="${LHTASK_GATE_BUILD:-}";;
    *) return 0;;
  esac
  if [ -n "$explicit" ]; then printf '%s' "$explicit"; return 0; fi
  if [ "$check" = test ] && [ -n "${LHTASK_TEST_CMD:-}" ] \
     && [ "$LHTASK_TEST_CMD" != "echo 'no test command configured' && false" ]; then
    printf '%s' "$LHTASK_TEST_CMD"; return 0
  fi
  stack="${LHTASK_STACK:-auto}"; [ "$stack" = auto ] && stack="$(lhtask_detect_stack)"
  case "${stack}:${check}" in
    nextjs:lint)      printf '%s' 'npm run -s lint';;
    nextjs:typecheck) printf '%s' 'npx -y tsc --noEmit';;
    nextjs:test)      printf '%s' 'npm test --silent';;
    nextjs:build)     printf '%s' 'npm run -s build';;
    react:lint)       printf '%s' 'npm run -s lint';;
    react:typecheck)  printf '%s' 'npx -y tsc --noEmit';;
    react:test)       printf '%s' 'npm test --silent';;
    node:lint)        printf '%s' 'npm run -s lint';;
    node:test)        printf '%s' 'npm test --silent';;
    python:lint)      printf '%s' 'ruff check {path}';;
    python:typecheck) printf '%s' 'mypy {path}';;
    python:test)      printf '%s' 'pytest {path} -q';;
    php:lint)         printf '%s' 'vendor/bin/phpcs {path}';;
    php:typecheck)    printf '%s' 'vendor/bin/phpstan analyse {path}';;
    php:test)         printf '%s' 'vendor/bin/pest';;
    go:lint)          printf '%s' 'gofmt -l .';;
    go:test)          printf '%s' 'go test ./...';;
    rust:lint)        printf '%s' 'cargo clippy -- -D warnings';;
    rust:test)        printf '%s' 'cargo test';;
    rust:build)       printf '%s' 'cargo build';;
    *) return 0;;   # no built-in for this (stack,check) → skip
  esac
}

# Build an --mcp-config flag array for headless claude (empty if no vendored config
# or codegraph disabled). Usage: lhtask_mcp_flags; claude … "${LHTASK_MCP_FLAGS[@]}"
# shellcheck disable=SC2034  # LHTASK_MCP_FLAGS is consumed by the caller.
lhtask_mcp_flags() {
  LHTASK_MCP_FLAGS=()
  if [ "${LHTASK_CODEGRAPH:-auto}" != off ] && [ -f "$LHTASK_ROOT/.mcp.json" ]; then
    LHTASK_MCP_FLAGS=(--mcp-config "$LHTASK_ROOT/.mcp.json")
  fi
  return 0
}

# Build a timeout prefix array for each headless phase (empty if no timeout tool —
# graceful no-op). macOS ships no `timeout`; use `gtimeout` (coreutils) if present.
# Usage: lhtask_timeout_cmd; "${LHTASK_TIMEOUT[@]}" claude …
# shellcheck disable=SC2034  # LHTASK_TIMEOUT is consumed by the caller.
lhtask_timeout_cmd() {
  LHTASK_TIMEOUT=()
  local t="${LHTASK_PHASE_TIMEOUT:-600}"
  if   command -v timeout  >/dev/null 2>&1; then LHTASK_TIMEOUT=(timeout "$t")
  elif command -v gtimeout >/dev/null 2>&1; then LHTASK_TIMEOUT=(gtimeout "$t")
  fi
  return 0
}

# Hard deny-rules for every headless role, as a --settings JSON string. Deny is
# evaluated first (deny→ask→allow) and cannot be re-allowed by any layer — so this
# blocks destructive/remote git + rm -rf + spontaneous Agent/Task spawns regardless
# of the per-role --allowed-tools or permission-mode.
lhtask_deny_settings() {
  printf '%s' '{"permissions":{"deny":["Bash(git push *)","Bash(git reset --hard *)","Bash(git rebase *)","Bash(rm -rf *)","Task","Agent"]}}'
}

# Print an agent .md body WITHOUT its YAML frontmatter (the header is config for
# interactive subagent loading; headless --append-system-prompt must not see it as
# literal noise). Files without frontmatter are printed verbatim.
lhtask_agent_body() {
  local f="$1"
  [ -f "$f" ] || return 0
  awk 'NR==1 && $0 !~ /^---[[:space:]]*$/ {plain=1} plain{print; next} /^---[[:space:]]*$/{c++; next} c>=2{print}' "$f"
}

# Highest severity across one or more EXPECTED review json files. FAIL-CLOSED:
# a missing/empty/unparseable/unrecognizable decision sidecar returns "blocker"
# (→ loopback, never a silent DONE). Echoes: blocker|major|minor|none.
lhtask_review_max_severity() {
  local max=0 rank f
  for f in "$@"; do
    if [ ! -s "$f" ]; then echo blocker; return; fi
    if command -v jq >/dev/null 2>&1 && ! jq -e . "$f" >/dev/null 2>&1; then echo blocker; return; fi
    if   grep -Eq '"severity"[[:space:]]*:[[:space:]]*"blocker"' "$f"; then rank=3
    elif grep -Eq '"severity"[[:space:]]*:[[:space:]]*"major"'   "$f"; then rank=2
    elif grep -Eq '"severity"[[:space:]]*:[[:space:]]*"minor"'   "$f"; then rank=1
    elif grep -Eq '"verdict"[[:space:]]*:[[:space:]]*"pass"'     "$f"; then rank=0
    else echo blocker; return; fi
    [ "$rank" -gt "$max" ] && max="$rank"
  done
  case "$max" in 3) echo blocker;; 2) echo major;; 1) echo minor;; *) echo none;; esac
}

# One-line human summary of a gate.json (failing check names).
lhtask_gate_summary() {
  local f="$1"
  [ -s "$f" ] || { printf 'gate result unavailable'; return; }
  if command -v jq >/dev/null 2>&1 && jq -e . "$f" >/dev/null 2>&1; then
    jq -r '[.checks[]?|select(.status=="fail")|.name] | if length>0 then "failed: "+join(", ") else "all checks passed/skipped" end' "$f"
  else
    if grep -Eq '"verdict"[[:space:]]*:[[:space:]]*"fail"' "$f"; then printf 'one or more checks failed (see gate.json)'; else printf 'all checks passed/skipped'; fi
  fi
}

# gate.json → ✅/❌/skip markdown lines (for TODO.review.md).
lhtask_json_checks_to_md() {
  local f="$1"
  [ -s "$f" ] || { printf -- '- gate result unavailable\n'; return; }
  if command -v jq >/dev/null 2>&1 && jq -e . "$f" >/dev/null 2>&1; then
    jq -r '.checks[]? | if .status=="pass" then "✅ gate:\(.name)" elif .status=="fail" then "❌ gate:\(.name) — \(.summary // "fail")" else "- gate:\(.name): skipped" end' "$f"
  elif grep -Eq '"verdict"[[:space:]]*:[[:space:]]*"fail"' "$f"; then
    printf '❌ gate: one or more checks failed (see gate.json)\n'
  else
    printf '✅ gate: all checks passed/skipped\n'
  fi
}

# review-<name>.json → ✅/⚠️/❌ markdown lines. Missing/unparseable → ❌ (fail-closed).
lhtask_json_findings_to_md() {
  local f="$1" agent
  agent="$(basename "$f" .json)"
  [ -s "$f" ] || { printf '❌ %s: report missing (treated as blocker)\n' "$agent"; return; }
  if command -v jq >/dev/null 2>&1; then
    if ! jq -e . "$f" >/dev/null 2>&1; then printf '❌ %s: unparseable report (treated as blocker)\n' "$agent"; return; fi
    jq -r --arg a "$agent" '(.agent // $a) as $n
      | if ((.findings|length)==0) and (.verdict=="pass") then "✅ \($n): ok"
        else (.findings[]? | (if (.severity=="blocker" or .severity=="major") then "❌ " elif .severity=="minor" then "⚠️ " else "⚠️ " end) + "\($n):\(.loc // "?") — \(.problem // "")") end' "$f"
  elif grep -Eq '"severity"[[:space:]]*:[[:space:]]*"(blocker|major)"' "$f"; then
    printf '❌ %s: blocker/major findings (see review json)\n' "$agent"
  elif grep -Eq '"severity"[[:space:]]*:[[:space:]]*"minor"' "$f"; then
    printf '⚠️ %s: minor findings\n' "$agent"
  elif grep -Eq '"verdict"[[:space:]]*:[[:space:]]*"pass"' "$f"; then
    printf '✅ %s: ok\n' "$agent"
  else
    printf '❌ %s: no recognizable verdict (treated as blocker)\n' "$agent"
  fi
}

# Surface review results: traffic-light summary line, ❌-loopback pointer into
# TODO.md under "## 🔎 Review-Findings", AGENT_LOG entry, optional notification.
# Reads $ROOT/TODO.review.md; uses $SHA for labels. (Moved here from lhtask-review.sh
# so the implement loop can reuse the exact same surface.)
lhtask_surface_review() {
  local root="${ROOT:-$LHTASK_ROOT}" sha="${SHA:-}"
  local report="$root/TODO.review.md"
  [ -f "$report" ] || return 0
  local ok warn bad
  ok="$(grep -c '✅' "$report" 2>/dev/null || true)";  ok="${ok:-0}"
  warn="$(grep -c '⚠️' "$report" 2>/dev/null || true)"; warn="${warn:-0}"
  bad="$(grep -c '❌' "$report" 2>/dev/null || true)";  bad="${bad:-0}"
  local line="LHTask review ${sha}: ✅ ${ok}  ⚠️ ${warn}  ❌ ${bad} — see TODO.review.md"
  echo "$line"

  if [ "$bad" -gt 0 ] 2>/dev/null; then
    local todo="$root/TODO.md"
    [ -f "$todo" ] || return 0
    awk 'BEGIN{s=0} /^## 🔎 Review-Findings/{s=1} s&&/^## /&&!/^## 🔎 Review-Findings/{s=0} !s{print}' "$todo" > "$todo.tmp" || cp "$todo" "$todo.tmp"
    {
      cat "$todo.tmp"
      printf '\n## 🔎 Review-Findings\n'
      printf -- '- ⚠️ %s — review of %s flagged %s ❌ finding(s). See TODO.review.md; resolve or re-file as a TODO.\n' \
        "$(date '+%Y-%m-%d %H:%M')" "$sha" "$bad"
    } > "$todo"
    rm -f "$todo.tmp"
    [ -f "$root/AGENT_LOG.md" ] && printf '\n## [%s] LHTask review %s — %s ❌, %s ⚠️ (see TODO.review.md)\n' \
      "$(date '+%Y-%m-%d %H:%M')" "$sha" "$bad" "$warn" >> "$root/AGENT_LOG.md"
  fi

  if [ "${LHTASK_NOTIFY:-0}" = "1" ]; then
    if command -v terminal-notifier >/dev/null 2>&1; then
      terminal-notifier -title "LHTask review ${sha}" -message "$line" 2>/dev/null || true
    elif command -v notify-send >/dev/null 2>&1; then
      notify-send "LHTask review ${sha}" "$line" 2>/dev/null || true
    fi
  fi
}

# Build TODO.review.md from the structured artifacts (gate + reviews), then hand off
# to lhtask_surface_review for the ## 🔎 / AGENT_LOG / notify surface (verbatim).
lhtask_findings_surface() {  # $1 = gate.json ; $2.. = review-*.json files
  local root="${ROOT:-$LHTASK_ROOT}" gate="$1" f; shift
  {
    printf '> Review of %s — %s\n\n' "${SHA:-autoplan/impl}" "$(date '+%Y-%m-%d %H:%M')"
    printf '### Gate\n'
    lhtask_json_checks_to_md "$gate"
    printf '\n### Reviews\n'
    for f in "$@"; do lhtask_json_findings_to_md "$f"; done
  } > "$root/TODO.review.md"
  lhtask_surface_review
}
