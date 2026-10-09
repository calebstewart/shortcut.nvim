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
# Runs one test file and quits: mini.test quits by itself once the file has run, but not if
# running it raises (e.g. the file has a syntax error), which would leave Neovim waiting forever.
RUN_FILE='local ok, err = pcall(MiniTest.run_file, vim.env.SHORTCUT_TEST_FILE);'\
' if not ok then io.stderr:write("error: " .. tostring(err) .. "\n"); vim.cmd("cquit 1") end'
export RUN_FILE

# One file per Neovim: a file's log and exit code are kept apart from the others'. Each status
# line is a single short write, so lines from parallel jobs don't interleave. NUL-separated, and
# the name is passed in the environment, so any file name works.
printf '%s\0' "$@" | xargs -0 -n 1 -P "$JOBS" sh -c '
  f=$1
  log="$out/$(printf %s "$f" | tr "/ " "__").log"
  t0=$(date +%s)
  if [ ! -f "$f" ]; then
    echo "error: no such test file: $f" >"$log"
    rc=1
  else
    # A log file of its own (also for the child Neovims the tests start): Neovims starting at
    # the same time with a fresh $HOME (as in the Nix sandbox) race to create the default log
    # directory, and the losers warn that the log is "not accessible", which tests then see.
    NVIM_LOG_FILE="$log.nvimlog" SHORTCUT_TEST_FILE="$f" \
      "$NVIM_BIN" --headless --noplugin -u tests/minimal_init.lua -c "lua $RUN_FILE" \
      >"$log" 2>&1 </dev/null
    rc=$?
  fi
  echo "$rc" >"$log.rc"
  if [ "$rc" -eq 0 ]; then status=ok; else status=FAIL; fi
  printf "%-4s %s (%ss)\n" "$status" "$f" "$(($(date +%s) - t0))"
' sh

failed=0
cases=0
for f in "$@"; do
  log="$out/$(printf %s "$f" | tr "/ " "__").log"
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
