#!/usr/bin/env bash
# Run all helm-schemas.nvim tests headlessly.
# Usage: ./test/run_tests.sh [test_file.lua]
set -e

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INIT="$PLUGIN_DIR/test/minimal_init.lua"
PLENARY_DIR="$HOME/.local/share/nvim/lazy/plenary.nvim"

if [ ! -d "$PLENARY_DIR" ]; then
  echo "ERROR: plenary.nvim not found at $PLENARY_DIR"
  echo "Install it via lazy.nvim first, then re-run."
  exit 1
fi

if [ -n "$1" ]; then
  # Run a single file
  TARGET="$PLUGIN_DIR/test/$1"
  echo "Running: $TARGET"
  nvim --headless -u "$INIT" \
    -c "lua require('plenary.test_harness').test_file('$TARGET', { minimal = true })" \
    -c "qa!"
else
  # Run all *_spec.lua files
  echo "Running all tests in $PLUGIN_DIR/test/"
  nvim --headless -u "$INIT" \
    -c "lua require('plenary.test_harness').test_directory('$PLUGIN_DIR/test/', { minimal = true })" \
    -c "qa!"
fi
