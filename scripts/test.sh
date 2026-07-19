#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NVIM="${NVIM:-nvim}"
if ! command -v "$NVIM" >/dev/null 2>&1; then
  echo "nvim not found" >&2
  exit 127
fi

echo "Running CSA.nvim tests with $NVIM..."
"$NVIM" --headless -u "$ROOT/tests/minimal_init.lua" -l "$ROOT/tests/run.lua"
echo "done."
