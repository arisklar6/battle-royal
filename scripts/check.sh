#!/usr/bin/env bash
# Mirror of CI's `check` job: nim-check every program, not just the test
# suite. The test suite alone missed a compile break in poster.nim for five
# pushes on 2026-08-18 (import-order-sensitive template) — this catches that
# class locally before CI does. Wire it as a pre-push hook with:
#   git config core.hooksPath scripts/hooks
set -e
cd "$(dirname "$0")/.."
for f in game/server.nim game/headless.nim game/analyst.nim \
         game/render.nim game/poster.nim player/baseline.nim; do
  echo "=== $f"
  nim check --hints:off "$f"
done
echo "all programs check clean"

# ...and compile-check the tests the way CI invokes them: bare `nim c`, no
# --path:src, no -p:game. A test that only builds with extra flags passes
# locally and fails in CI — t_slot_labels reached master that way on 0.1.16,
# using `import render` where the house pattern is `import ../game/render`.
# Checking (not running) keeps the hook fast; CI still runs them.
for t in tests/t_*.nim; do
  echo "=== $t"
  nim check --hints:off "$t"
done
echo "all tests check clean"
