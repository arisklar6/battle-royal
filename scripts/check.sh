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
