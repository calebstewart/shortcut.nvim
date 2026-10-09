#!/bin/sh
# Run test files, each in its own headless Neovim, $JOBS at a time (default: one per CPU).
#
#   tests/run.sh [file...]      default: every tests/test_*.lua
#
# Prints a line per file as it finishes, then the full output of every file that failed or has
# notes (e.g. skipped tests), or of every file with VERBOSE=1. Exits non-zero if any file
# failed. Used by `make test`, which also sets MINI_NVIM and SNACKS_NVIM.
set -u

NVIM_BIN=${NVIM_BIN:-nvim}
# Empty or 0 (as Nix's NIX_BUILD_CORES may be): one per CPU.
case ${JOBS:-} in '' | *[!0-9]* | 0) JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null) ;; esac
case $JOBS in '' | *[!0-9]* | 0) JOBS=4 ;; esac

cd "$(dirname "$0")/.." || exit 1
[ $# -gt 0 ] || set -- tests/test_*.lua

out=$(mktemp -d "${TMPDIR:-/tmp}/shortcut-tests.XXXXXX") || exit 1
trap 'rm -rf "$out"' EXIT INT TERM
export NVIM_BIN out

start=$(date +%s)
# One file per Neovim: a file's log and exit code are kept apart from the others'. Each status
# line is a single short write, so lines from parallel jobs don't interleave.
printf '%s\n' "$@" | xargs -n 1 -P "$JOBS" sh -c '
  f=$1
  log="$out/$(printf %s "$f" | tr / _).log"
  t0=$(date +%s)
  "$NVIM_BIN" --headless --noplugin -u tests/minimal_init.lua \
    -c "lua MiniTest.run_file([==[$f]==])" >"$log" 2>&1 </dev/null
  rc=$?
  echo "$rc" >"$log.rc"
  if [ "$rc" -eq 0 ]; then status=ok; else status=FAIL; fi
  printf "%-4s %s (%ss)\n" "$status" "$f" "$(($(date +%s) - t0))"
' sh

failed=0
cases=0
for f in "$@"; do
  log="$out/$(printf %s "$f" | tr / _).log"
  rc=$(cat "$log.rc" 2>/dev/null || echo 1)
  # mini.test colours its report: drop the escape sequences first.
  n=$(tr -d '\033' <"$log" 2>/dev/null \
    | sed -n 's/.*Total number of cases:\(\[[0-9;]*m\)* *\([0-9][0-9]*\).*/\2/p' | head -n 1)
  cases=$((cases + ${n:-0}))
  # Notes are e.g. skipped tests (the snacks picker tests, when snacks.nvim is missing).
  notes=$(tr -d '\033' <"$log" 2>/dev/null | sed -n 's/.*Notes (\([0-9][0-9]*\)).*/\1/p' | head -n 1)
  if [ "$rc" -ne 0 ] || [ "${notes:-0}" -gt 0 ] || [ "${VERBOSE:-0}" = 1 ]; then
    printf '\n===== %s (exit %s) =====\n' "$f" "$rc"
    cat "$log" 2>/dev/null
    echo
  fi
  [ "$rc" -eq 0 ] || failed=$((failed + 1))
done

printf '\n%d files, %d cases, %d failed files, %ss\n' "$#" "$cases" "$failed" "$(($(date +%s) - start))"
[ "$failed" -eq 0 ]
