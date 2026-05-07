#!/bin/sh
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
  printf '%s' "$haystack" | grep -F "$needle" >/dev/null 2>&1
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

if ASKGPT_MEMORY_FILE="$WORKDIR/memory.txt" "$SCRIPT" --dry-run --max-bytes 3 -f "$sample" "Review this" >/dev/null 2>&1; then
  fail "max-bytes refuses oversized file"
fi
pass "max-bytes refuses oversized file"

printf 'basic local tests passed\n'
