#!/usr/bin/env bash
#
# lhtask-review.sh — STAGE 3 (REVIEW) of the LHTask agent chain.
#
# Usage: lhtask-review.sh [TARGET]
#   TARGET defaults to HEAD (the human commit that touched a review dir).
#   When called with the impl branch (e.g. autoplan/impl), it reviews the
#   commits that branch introduces over HEAD — so the AUTONOMOUS work gets a
#   review too (the post-commit hook can't, since agent commits set AUTOPLAN_AGENT=1).
#
# Asks headless Claude whether the change correctly implements the related
# TODO/plan item and follows the constitution conventions. Writes a report to the
# gitignored sidecar TODO.review.md. Report-only: never commits to code, never blocks.
# On ❌ findings it surfaces a pointer under "## 🔎 Review-Findings" in TODO.md
# (human-owned; the skip convention keeps the chain from acting on it) + AGENT_LOG.
#
set -euo pipefail

# Git exports GIT_DIR/GIT_INDEX_FILE/… into post-commit hook subprocesses; clear
# them so our own git commands resolve against the working dir, not the hook's
# quarantined index.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_QUARANTINE_PATH 2>/dev/null || true

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
# shellcheck source=scripts/lhtask-lib.sh
. "$ROOT/scripts/lhtask-lib.sh"
lhtask_load_config
lhtask_model_flags review  # stage-level override: LHTASK_MODEL_REVIEW

git rev-parse HEAD~1 >/dev/null 2>&1 || exit 0
command -v claude >/dev/null 2>&1 || { echo "lhtask-review: claude CLI not found, skipping." >&2; exit 0; }

TARGET="${1:-HEAD}"
# Chained from implement (a TARGET arg was passed) → append to the existing run
# log; standalone trigger (no arg) → it owns a fresh run log.
CHAINED=0; [ "$#" -ge 1 ] && CHAINED=1
SHA="$(git rev-parse --short "$TARGET" 2>/dev/null || echo "$TARGET")"
LOCKDIR="$ROOT/.git/lhtask-review.lock"
LOG="$ROOT/.git/lhtask-review.log"
RUNLOG="$ROOT/TODO.run.log"

# Decide what to inspect: a branch tip → the range it introduces over HEAD; else
# the single target commit.
if git show-ref --verify --quiet "refs/heads/$TARGET" && [ "$(git rev-parse "$TARGET")" != "$(git rev-parse HEAD)" ]; then
  SCOPE="branch ${TARGET} (autonomous work): inspect every commit it introduces with \`git log --stat HEAD..${TARGET}\` and \`git show <sha>\` per commit"
  WHAT="the autonomous implementation on branch ${TARGET}"
  # Fallow analyzes the CHECKED-OUT tree; a branch target isn't checked out here —
  # and its commits were already fallow-gated inside the implement worktree.
  FALLOW_BASE=""
else
  SCOPE="commit ${SHA}: inspect with \`git show ${SHA}\` and \`git show --stat ${SHA}\`"
  WHAT="commit ${SHA}"
  FALLOW_BASE="${TARGET}~1"
fi

read -r -d '' PROMPT <<EOF || true
$(lhtask_preamble)

Review ${WHAT}: does it correctly and completely implement the related TODO/plan
item, and does it follow the conventions in the constitution files?

Procedure (read-only): ${SCOPE}, read the affected files, and cross-check against
TODO.md, DONE.md and TODO.autoplan.md.

Write a concise review report EXCLUSIVELY to TODO.review.md (overwrite). Start with
"> Review of ${WHAT} — $(date '+%Y-%m-%d %H:%M')". One line per checked aspect:
✅ met / ⚠️ deviation / ❌ missing, each with a short reason and file reference.
Do not change any other file, do not commit. A report only.
EOF

lhtask_reap_stale_lock "$LOCKDIR" 15
mkdir "$LOCKDIR" 2>/dev/null || exit 0

# Standalone trigger owns a fresh run log; chained review appends to the existing one.
[ "$CHAINED" = 0 ] && lhtask_runlog_reset "$RUNLOG"

printf '> ⏳ Review of %s running since %s … report appears here when done.\n' \
  "$SHA" "$(date '+%H:%M:%S')" > "$ROOT/TODO.review.md"
echo "→ LHTask review started (${SHA}); report in TODO.review.md (~1–2 min)."

# lhtask_surface_review now lives in lhtask-lib.sh (shared with lhtask-implement.sh).
# It reads $ROOT/TODO.review.md and uses $SHA — both set above — so behaviour is unchanged.

do_run() {
  trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT
  lhtask_runlog_stage "$RUNLOG" "REVIEW (${SHA})"
  # AUTOPLAN_AGENT=1 defensively prevents any git activity from recursing.
  { AUTOPLAN_AGENT=1 claude -p "$PROMPT" \
      --permission-mode acceptEdits \
      --allowed-tools Read Write Glob Grep Bash \
      ${LHTASK_MODEL_FLAGS[@]+"${LHTASK_MODEL_FLAGS[@]}"} 2>&1 || true; } | tee -a "$RUNLOG" >"$LOG"
  # Fallow static analysis (dead code / duplication / complexity) — part of every
  # review. Appended BEFORE the surface so its ❌ counts toward the 🔎 pointer.
  # Exit 1 (findings) is data, not an error; no fallow installed → no section.
  if [ -n "$FALLOW_BASE" ]; then
    FCMD="$(lhtask_fallow_cmd "$FALLOW_BASE")"
    if [ -n "$FCMD" ]; then
      FJSON="$ROOT/.git/lhtask-fallow.json"
      eval "$FCMD" >"$FJSON" 2>>"$LOG" || true
      { printf '\n### Fallow (static analysis)\n'
        lhtask_fallow_to_md "$FJSON" | sed 's|\.lhtask-state/fallow\.json|.git/lhtask-fallow.json|'
      } >> "$ROOT/TODO.review.md"
    fi
  fi
  lhtask_surface_review | tee -a "$RUNLOG"
}

if [ -n "${LHTASK_FOREGROUND:-}" ]; then
  ( do_run )
else
  ( do_run ) </dev/null >/dev/null 2>&1 &
fi

exit 0
