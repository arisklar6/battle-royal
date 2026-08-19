#!/usr/bin/env bash
# Mirror of CI's `check` job: nim-check every program, not just the test
# suite. The test suite alone missed a compile break in poster.nim for five
# pushes on 2026-08-18 (import-order-sensitive template) — this catches that
# class locally before CI does. Wire it as a pre-push hook with:
#   git config core.hooksPath scripts/hooks
set -u
cd "$(dirname "$0")/.."

# Deliberately NOT `set -e`: aborting at the first failure hides every later
# one, and both loops below are alphabetical, so a single early break makes
# a broad breakage look like a one-line fix. Collect and report the full set.
fail=0
failed=""
note_fail() { echo "FAILED: $1"; failed="$failed $1"; fail=1; }

for f in game/server.nim game/headless.nim game/analyst.nim \
         game/render.nim game/poster.nim player/baseline.nim; do
  echo "=== $f"
  nim check --hints:off "$f" || note_fail "$f"
done

# ...and compile-check the tests the way CI invokes them: bare `nim c`, no
# --path:src, no -p:game. A test that only builds with extra flags passes
# locally and fails in CI — t_slot_labels reached master that way on 0.1.16,
# using `import render` where the house pattern is `import ../game/render`.
# Checking (not running) keeps the hook fast; CI still runs them.
for t in tests/t_*.nim; do
  echo "=== $t"
  nim check --hints:off "$t" || note_fail "$t"
done

if [ "$fail" -ne 0 ]; then
  echo
  echo "check FAILED:$failed"
  exit 1
fi
echo "all programs and tests check clean"
