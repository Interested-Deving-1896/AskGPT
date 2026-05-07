#!/bin/sh
#
# Copyright (c) 2026 James Elstone
# SPDX-License-Identifier: BSD-3-Clause
# See ../LICENSE for full license text.

set -eu

SCRIPT="${SCRIPT:-./askgpt.sh}"
TMPDIR="${TMPDIR:-/tmp}"
WORKDIR="$(mktemp -d "${TMPDIR}/askgpt-tests.XXXXXX")"

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT HUP INT TERM

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

contains() {
  haystack="$1"
  needle="$2"
  printf '%s' "$haystack" | grep -F -- "$needle" >/dev/null 2>&1
}

sh -n "$SCRIPT"
pass "script parses"

ASKGPT_MEMORY_FILE="$WORKDIR/memory.txt" "$SCRIPT" remember "alpha secret" >/dev/null
memory_output="$(ASKGPT_MEMORY_FILE="$WORKDIR/memory.txt" "$SCRIPT" memory)"
contains "$memory_output" "alpha secret" || fail "memory command shows remembered text"
pass "memory command shows remembered text"

ASKGPT_MEMORY_FILE="$WORKDIR/memory.txt" "$SCRIPT" forget >/dev/null
memory_output="$(ASKGPT_MEMORY_FILE="$WORKDIR/memory.txt" "$SCRIPT" memory)"
contains "$memory_output" "No memory saved." || fail "forget clears memory"
pass "forget clears memory"

sample="$WORKDIR/sample.txt"
printf 'OPENAI_API_KEY=sk-testsecret000000000000000000\nhello\n' > "$sample"
dry_output="$(ASKGPT_MEMORY_FILE="$WORKDIR/memory.txt" "$SCRIPT" --dry-run -f "$sample" "Review this")"
contains "$dry_output" "[REDACTED" || fail "dry-run redacts secrets"
contains "$dry_output" "Review this" || fail "dry-run includes prompt"
pass "dry-run redacts and includes prompt"

update_dry_output="$(ASKGPT_MEMORY_FILE="$WORKDIR/memory.txt" "$SCRIPT" --dry-run -f "$sample" -u "Improve this")"
contains "$update_dry_output" "ASKGPT_DIFF_START" || fail "update dry-run includes diff instructions"
contains "$update_dry_output" "--- a/sample.txt" || fail "update dry-run names target diff path"
pass "update dry-run includes patch instructions"

new_file="$WORKDIR/NewClass.php"
new_file_output="$(ASKGPT_MEMORY_FILE="$WORKDIR/memory.txt" "$SCRIPT" --dry-run -f "$new_file" -u "Create a new class called Test")"
contains "$new_file_output" "This file does not exist yet" || fail "new update target is sent as empty file"
contains "$new_file_output" "If the target file does not exist yet" || fail "new update target includes creation instruction"
pass "missing update target can seed a new file"

if ASKGPT_MEMORY_FILE="$WORKDIR/memory.txt" "$SCRIPT" --dry-run --max-bytes 3 -f "$sample" "Review this" >/dev/null 2>&1; then
  fail "max-bytes refuses oversized file"
fi
pass "max-bytes refuses oversized file"

printf 'basic local tests passed\n'
