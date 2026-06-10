#!/usr/bin/env bash
set -euo pipefail

# Smoke test: bootstrap LHTask into a throwaway repo and run one cycle.
# Run with: bash tests/smoke-test.sh
# Prerequisites: claude CLI on PATH, LHTask plugin accessible.

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "=== LHTask Smoke Test ==="
echo "Plugin dir: $PLUGIN_DIR"
echo "Working in:  $TMPDIR"

# --- Unit: per-role model resolution (pure shell, no claude needed) ---
echo ""
echo "--- Unit: lhtask_model_flags resolution ---"
(
  cd "$TMPDIR"
  git init -q model-unit && cd model-unit   # lib needs a git toplevel
  # shellcheck source=/dev/null
  . "$PLUGIN_DIR/templates/scripts/lhtask-lib.sh"
  lhtask_load_config

  assert_flags() {  # $1 = label, $2 = expected ("--model X" or empty)
    local got="${LHTASK_MODEL_FLAGS[*]:-}"
    if [ "$got" = "$2" ]; then echo "  ok:  $1"
    else echo "  UNIT FAIL: $1 — expected '$2', got '$got'"; exit 1; fi
  }

  # 1) no config at all → empty (CLI default)
  lhtask_model_flags implementer
  assert_flags "no override → empty" ""
  # 2) global only → global wins for any role and for no-role calls
  LHTASK_MODEL="opus"
  lhtask_model_flags implementer
  assert_flags "global fallback (role)" "--model opus"
  lhtask_model_flags
  assert_flags "global fallback (no role, legacy)" "--model opus"
  # 3) role-specific beats global; dash→underscore mapping
  LHTASK_MODEL_REVIEWER_CORRECTNESS="sonnet"
  lhtask_model_flags reviewer-correctness
  assert_flags "role-specific beats global (+ - → _ mapping)" "--model sonnet"
  # 4) other roles keep falling back to global
  lhtask_model_flags reviewer-conventions
  assert_flags "unset role falls back to global" "--model opus"
  # 5) stage names map too
  LHTASK_MODEL_REVIEW="haiku"
  lhtask_model_flags review
  assert_flags "stage name (review)" "--model haiku"
  LHTASK_MODEL_PLAN="haiku"
  lhtask_model_flags plan
  assert_flags "stage name (plan)" "--model haiku"
  echo "  model-resolution unit tests passed"
) || { echo "SMOKE FAIL: model resolution unit tests"; exit 1; }

cd "$TMPDIR"

# --- Setup: create a throwaway git repo ---
git init
git config user.email "test@lhtask.local"
git config user.name "LHTask Test"

cp "$PLUGIN_DIR/templates/AGENTS.md" .

cat > TODO.md <<'EOF'
## Backlog
- [ ] test: add a simple hello-world script
EOF
git add -A && git commit -m "init"

# --- Bootstrap the chain ---
echo ""
echo "--- Bootstrapping LHTask into throwaway repo ---"
claude -p --plugin-dir "$PLUGIN_DIR" "/lhtask:bootstrap" || {
  echo "SMOKE FAIL: bootstrap did not complete"
  exit 1
}

# --- Add a task and commit to trigger the chain ---
cat > TODO.md <<'EOF'
## Backlog
- [ ] feat: create hello.sh that prints "hello world"
EOF
git add TODO.md && git commit -m "task: add hello script"

# --- Run the chain in foreground ---
echo ""
echo "--- Running implement chain (foreground) ---"
LHTASK_FOREGROUND=1 .githooks/post-commit

# --- Verify ---
echo ""
if [ -f TODO.run.log ]; then
  echo "SMOKE PASS: TODO.run.log created"
else
  echo "SMOKE FAIL: No TODO.run.log"
  exit 1
fi

echo "All smoke tests passed."
