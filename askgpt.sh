#!/bin/sh
#
# Copyright (c) 2026 James Elstone
# SPDX-License-Identifier: BSD-3-Clause
# See LICENSE for full license text.

MODEL="${OPENAI_MODEL:-gpt-5.4-mini}"
API_URL="${OPENAI_API_URL:-https://api.openai.com/v1/responses}"

OPENAI_API_KEY_FILES="${OPENAI_API_KEY_FILE:-$HOME/.config/openai/api_key /usr/local/etc/openai_api_key}"

MEMORY_FILE="${ASKGPT_MEMORY_FILE:-$HOME/.config/openai/askgpt_memory.txt}"
SYSTEM_FILE="${ASKGPT_SYSTEM_FILE:-$HOME/.config/openai/askgpt_system.txt}"

MAX_BYTES="${ASKGPT_MAX_BYTES:-1048576}"
CURL_CONNECT_TIMEOUT="${ASKGPT_CONNECT_TIMEOUT:-10}"
CURL_TIMEOUT="${ASKGPT_TIMEOUT:-120}"
CURL_RETRIES="${ASKGPT_RETRIES:-2}"

USE_MEMORY=1
USE_SYSTEM=1
DRY_RUN=0
STREAM=0
JSON_OUTPUT=0
PREVIEW=0
COPY_OUTPUT=0
SAVE_FILE=""
SYSTEM_TEXT=""
UPDATE_MODE=0
UPDATE_FILE=""
FIRST_FILE=""
PATCH_ONLY=0
ASSUME_YES=0
BACKUP=1

usage() {
  cat <<'EOF'
Usage:
  askgpt [options] "question"
  askgpt [options] -f file... "question"
  askgpt -f file -u "change request"
  askgpt --update file "change request"
  command | askgpt [options] "question"
  askgpt remember: text
  askgpt remember "text"
  askgpt memory
  askgpt forget

Examples:
  askgpt "Explain rc.conf"
  askgpt -f /etc/rc.conf "Explain this FreeBSD config"
  askgpt -f index.php -f lib/Service.php "Review these for bugs"
  tail -200 /var/log/messages | askgpt "Summarise this log"
  askgpt --dry-run -f config.php "Check this before I send it"
  askgpt --stream "Write a short deployment checklist"
  askgpt --save answer.md -f index.php "Review this file"
  askgpt -f a_file.php -u "Improve the security of this file"
  askgpt -f NewClass.php -u "Create a new class called Test"
  askgpt --update a_file.php "Improve the security of this file"

Memory examples:
  askgpt remember: 123789
  askgpt remember "My favourite database is PostgreSQL"
  askgpt memory
  askgpt forget
  askgpt --no-memory "Ignore stored notes for this answer"

Options:
  -m, --model MODEL        Override model for this request
  -f, --file FILE          Add a file to the prompt context
  --max-bytes BYTES        Maximum bytes per file/stdin before refusing
  --no-memory              Do not include persistent local memory
  --system TEXT            Add request-specific system/developer guidance
  --system-file FILE       Load request-specific guidance from a file
  --no-system              Do not load the default system file
  --dry-run                Print the exact redacted prompt and exit
  --preview                List attached inputs and prompt size before sending
  --stream                 Stream response text as it arrives
  --json                   Print the full JSON response instead of text
  --save FILE              Save the assistant text to a file
  --copy                   Copy assistant text to the clipboard, when available
  -u, --update-file        Ask for a patch and update the first -f file
  --update FILE            Ask for a patch and update this specific file
  --patch-only             Print the proposed patch but do not apply it
  -y, --yes                Apply update patch without confirmation
  --backup                 Create a .bak.TIMESTAMP backup before patching
  --no-backup              Do not create a backup before patching
  -h, --help               Show this help

Environment:
  OPENAI_API_KEY           API key, preferred if set
  OPENAI_API_KEY_FILE      Optional single key-file override
  OPENAI_MODEL             Optional default model
  OPENAI_API_URL           Optional API endpoint override
  ASKGPT_MEMORY_FILE       Optional memory file override
  ASKGPT_SYSTEM_FILE       Optional default system/developer guidance file
  ASKGPT_MAX_BYTES         Optional per-input byte limit, default 1048576
  ASKGPT_TIMEOUT           Optional curl total timeout, default 120
  ASKGPT_CONNECT_TIMEOUT   Optional curl connect timeout, default 10
  ASKGPT_RETRIES           Optional curl retry count, default 2

Default key lookup order:
  1. OPENAI_API_KEY environment variable
  2. OPENAI_API_KEY_FILE, if set
  3. $HOME/.config/openai/api_key
  4. /usr/local/etc/openai_api_key

Default memory file:
  $HOME/.config/openai/askgpt_memory.txt

Default system file:
  $HOME/.config/openai/askgpt_system.txt
EOF
}

die() {
  echo "$*" >&2
  exit 1
}

check_dependencies() {
  missing=""

  for cmd in curl jq sed grep head tr dirname date wc mktemp cp; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing="${missing} ${cmd}"
    fi
  done

  if [ -n "$missing" ]; then
    echo "Missing required command(s):${missing}" >&2
    echo "" >&2
    echo "Install the main dependencies on FreeBSD with:" >&2
    echo "  pkg install curl jq ca_root_nss" >&2
    exit 127
  fi
}

ensure_parent_file() {
  target_file="$1"
  mode="$2"
  target_dir="$(dirname "$target_file")"

  if [ ! -d "$target_dir" ]; then
    mkdir -p "$target_dir" || die "Could not create directory: $target_dir"
    chmod 700 "$target_dir" 2>/dev/null
  fi

  if [ ! -f "$target_file" ]; then
    : > "$target_file" || die "Could not create file: $target_file"
    chmod "$mode" "$target_file" 2>/dev/null
  fi
}

ensure_memory_file() {
  ensure_parent_file "$MEMORY_FILE" 600
}

redact_text() {
  sed -E '
    s/(password|passwd|secret|token|api[_-]?key)[[:space:]]*=[[:space:]]*.*/\1 = [REDACTED]/Ig
    s/(Authorization:[[:space:]]*Bearer[[:space:]]+).*/\1[REDACTED]/Ig
    s/(OPENAI_API_KEY[[:space:]]*=[[:space:]]*).*/\1[REDACTED]/Ig
    s/(sk-[A-Za-z0-9_-]{20,})/[REDACTED_OPENAI_KEY]/g
  '
}

redact_file() {
  redact_text < "$1"
}

get_api_key() {
  if [ -z "$OPENAI_API_KEY" ]; then
    for key_file in $OPENAI_API_KEY_FILES; do
      if [ -r "$key_file" ]; then
        OPENAI_API_KEY="$(head -n 1 "$key_file" | tr -d '\r\n')"
        break
      fi
    done
  fi
}

validate_bytes_number() {
  case "$1" in
    ''|*[!0-9]*)
      die "Expected a positive byte count, got: $1"
      ;;
  esac
}

byte_count() {
  wc -c < "$1" | tr -d '[:space:]'
}

is_binary_file() {
  # jq will not accept NUL bytes in JSON strings, and binary blobs are rarely
  # helpful context. grep -Iq is available on the target BSD/GNU platforms.
  if [ "$(byte_count "$1")" -eq 0 ]; then
    return 1
  fi

  if grep -Iq . "$1" 2>/dev/null; then
    return 1
  fi
  return 0
}

validate_input_file() {
  path="$1"
  label="$2"

  [ -f "$path" ] || die "File not found: $label"
  [ -r "$path" ] || die "File is not readable: $label"

  input_bytes="$(byte_count "$path")"
  if [ "$input_bytes" -gt "$MAX_BYTES" ]; then
    die "$label is ${input_bytes} bytes, over the limit of ${MAX_BYTES}. Use --max-bytes to override."
  fi

  if is_binary_file "$path"; then
    die "$label looks like a binary file. Refusing to send it as prompt text."
  fi
}

validate_new_update_target() {
  path="$1"
  target_dir="$(dirname "$path")"

  [ ! -e "$path" ] || return 0
  [ -d "$target_dir" ] || die "Update target directory does not exist: $target_dir"
  [ -w "$target_dir" ] || die "Update target directory is not writable: $target_dir"
}

append_file_context() {
  file="$1"
  CONTEXT="${CONTEXT}

===== FILE: ${file} =====
$(redact_file "$file")
===== END FILE: ${file} =====
"
}

append_new_file_context() {
  file="$1"
  CONTEXT="${CONTEXT}

===== FILE: ${file} =====
[This file does not exist yet. Treat it as a new empty file to create.]
===== END FILE: ${file} =====
"
}

extract_text_response() {
  jq -r '
    if .error then
      empty
    elif .output_text then
      .output_text
    elif (.output? and (.output | type == "array")) then
      [
        .output[]
        | select(.type? == "message")
        | .content[]?
        | select(.type? == "output_text" or .type? == "text")
        | .text?
      ]
      | join("\n")
    else
      empty
    end
  '
}

print_api_error() {
  response_file="$1"
  http_status="$2"

  if jq -e '.error' "$response_file" >/dev/null 2>&1; then
    jq -r '"API error: " + (.error.message // (.error | tostring))' "$response_file" >&2
  else
    echo "API request failed with HTTP status ${http_status}." >&2
    echo "Response body:" >&2
    cat "$response_file" >&2
  fi
}

copy_to_clipboard() {
  text_file="$1"

  if command -v pbcopy >/dev/null 2>&1; then
    pbcopy < "$text_file"
  elif command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard < "$text_file"
  elif command -v wl-copy >/dev/null 2>&1; then
    wl-copy < "$text_file"
  elif command -v clip.exe >/dev/null 2>&1; then
    clip.exe < "$text_file"
  else
    die "No clipboard command found. Tried pbcopy, xclip, wl-copy, and clip.exe."
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

extract_between_markers() {
  start_marker="$1"
  end_marker="$2"
  source_file="$3"

  sed -n "/^${start_marker}\$/,/^${end_marker}\$/p" "$source_file" | sed '1d;$d'
}

patch_check() {
  patch_dir="$1"
  patch_file="$2"

  if patch -d "$patch_dir" -p1 --dry-run < "$patch_file" >/dev/null 2>&1; then
    return 0
  fi

  if patch -d "$patch_dir" -p1 -C < "$patch_file" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

make_payload() {
  stream_flag="$1"

  jq -n \
    --arg model "$MODEL" \
    --arg input "$FULL_INPUT" \
    --argjson stream "$stream_flag" \
    '{
      model: $model,
      input: $input
    } + if $stream then {stream: true} else {} end'
}

run_stream_request() {
  payload_file="$1"

  curl -sS -N "$API_URL" \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" \
    --max-time "$CURL_TIMEOUT" \
    --retry "$CURL_RETRIES" \
    --retry-delay 1 \
    -H "Authorization: Bearer ${OPENAI_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "@${payload_file}" |
  while IFS= read -r line; do
    case "$line" in
      data:\ *)
        data="${line#data: }"
        [ "$data" = "[DONE]" ] && break
        printf '%s\n' "$data" |
          jq -j '
            if .type == "response.output_text.delta" then
              .delta
            elif .type == "response.completed" then
              empty
            elif .type == "error" then
              "\nAPI error: " + (.message // tostring)
            else
              empty
            end
          ' 2>/dev/null
        ;;
    esac
  done
  printf '\n'
}

handle_update_response() {
  answer_file="$1"
  target_file="$2"

  require_command patch
  require_command basename

  update_dir="$(dirname "$target_file")"
  update_base="$(basename "$target_file")"

  [ -d "$update_dir" ] || die "Update target directory does not exist: $update_dir"
  if [ -e "$target_file" ]; then
    [ -f "$target_file" ] || die "Update target is not a regular file: $target_file"
    [ -w "$target_file" ] || die "Update target is not writable: $target_file"
  else
    [ -w "$update_dir" ] || die "Update target directory is not writable: $update_dir"
  fi

  EXPLANATION_TMP="$(mktemp "${TMPDIR:-/tmp}/askgpt.explanation.XXXXXX")" || die "Could not create temporary explanation file."
  DIFF_TMP="$(mktemp "${TMPDIR:-/tmp}/askgpt.diff.XXXXXX")" || die "Could not create temporary diff file."

  extract_between_markers "--- ASKGPT_EXPLANATION_START ---" "--- ASKGPT_EXPLANATION_END ---" "$answer_file" > "$EXPLANATION_TMP"
  extract_between_markers "--- ASKGPT_DIFF_START ---" "--- ASKGPT_DIFF_END ---" "$answer_file" > "$DIFF_TMP"

  if [ ! -s "$DIFF_TMP" ]; then
    echo "The API response did not contain a usable patch. Full response follows:" >&2
    cat "$answer_file" >&2
    exit 1
  fi

  if [ -s "$EXPLANATION_TMP" ]; then
    cat "$EXPLANATION_TMP"
    printf '\n'
  else
    cat "$answer_file"
    printf '\n'
  fi

  echo "Proposed patch:"
  cat "$DIFF_TMP"

  if [ "$PATCH_ONLY" -eq 1 ]; then
    echo "Patch not applied because --patch-only was used." >&2
    return 0
  fi

  if ! patch_check "$update_dir" "$DIFF_TMP"; then
    echo "Patch did not apply cleanly. No files were changed." >&2
    exit 1
  fi

  if [ "$ASSUME_YES" -ne 1 ]; then
    printf 'Apply changes to %s? [y/N] ' "$target_file" >&2
    IFS= read -r reply
    case "$reply" in
      y|Y|yes|YES)
        ;;
      *)
        echo "Patch not applied." >&2
        return 0
        ;;
    esac
  fi

  if [ "$BACKUP" -eq 1 ]; then
    if [ -e "$target_file" ]; then
      backup_file="${target_file}.bak.$(date '+%Y%m%d%H%M%S')"
      cp "$target_file" "$backup_file" || die "Could not create backup: $backup_file"
      echo "Backup created: $backup_file" >&2
    else
      echo "No backup created because this is a new file." >&2
    fi
  fi

  patch -d "$update_dir" -p1 < "$DIFF_TMP" >/dev/null || die "Patch failed while applying changes."
  echo "Updated: $target_file" >&2
}

check_dependencies
ensure_memory_file

FILES=""
PROMPT=""
COMMAND=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -m|--model)
      shift
      [ -n "$1" ] || die "Missing model after -m/--model"
      MODEL="$1"
      ;;
    -f|--file)
      shift
      [ -n "$1" ] || die "Missing file after -f/--file"
      case "$1" in
        *"
"*) die "Filenames containing newlines are not supported." ;;
      esac
      FILES="${FILES}
$1"
      if [ -z "$FIRST_FILE" ]; then
        FIRST_FILE="$1"
      fi
      ;;
    --max-bytes)
      shift
      [ -n "$1" ] || die "Missing value after --max-bytes"
      validate_bytes_number "$1"
      MAX_BYTES="$1"
      ;;
    --no-memory)
      USE_MEMORY=0
      ;;
    --system)
      shift
      [ -n "$1" ] || die "Missing text after --system"
      SYSTEM_TEXT="${SYSTEM_TEXT}
$1"
      ;;
    --system-file)
      shift
      [ -n "$1" ] || die "Missing file after --system-file"
      validate_input_file "$1" "$1"
      SYSTEM_TEXT="${SYSTEM_TEXT}
$(redact_file "$1")"
      ;;
    --no-system)
      USE_SYSTEM=0
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --preview)
      PREVIEW=1
      ;;
    --stream)
      STREAM=1
      ;;
    --json)
      JSON_OUTPUT=1
      ;;
    --save)
      shift
      [ -n "$1" ] || die "Missing file after --save"
      SAVE_FILE="$1"
      ;;
    --copy)
      COPY_OUTPUT=1
      ;;
    -u|--update-file)
      UPDATE_MODE=1
      ;;
    --update)
      shift
      [ -n "$1" ] || die "Missing file after --update"
      UPDATE_MODE=1
      UPDATE_FILE="$1"
      if [ -z "$FIRST_FILE" ]; then
        FIRST_FILE="$1"
      fi
      FILES="${FILES}
$1"
      ;;
    --patch-only)
      PATCH_ONLY=1
      ;;
    -y|--yes)
      ASSUME_YES=1
      ;;
    --backup)
      BACKUP=1
      ;;
    --no-backup)
      BACKUP=0
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do
        if [ -z "$PROMPT" ]; then
          PROMPT="$1"
        else
          PROMPT="${PROMPT} $1"
        fi
        shift
      done
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    remember|memory|forget)
      if [ -z "$PROMPT" ] && [ -z "$COMMAND" ]; then
        COMMAND="$1"
      else
        PROMPT="${PROMPT} $1"
      fi
      ;;
    *)
      if [ -z "$PROMPT" ]; then
        PROMPT="$1"
      else
        PROMPT="${PROMPT} $1"
      fi
      ;;
  esac
  shift
done

if [ "$COMMAND" = "remember" ]; then
  MEMORY_TEXT="$PROMPT"
  [ -n "$MEMORY_TEXT" ] || die "Nothing to remember."
  printf '%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$MEMORY_TEXT" >> "$MEMORY_FILE"
  echo "Remembered: $MEMORY_TEXT"
  exit 0
fi

if [ "$COMMAND" = "memory" ]; then
  if [ -s "$MEMORY_FILE" ]; then
    cat "$MEMORY_FILE" | redact_text
  else
    echo "No memory saved."
  fi
  exit 0
fi

if [ "$COMMAND" = "forget" ]; then
  : > "$MEMORY_FILE" || die "Could not clear memory file: $MEMORY_FILE"
  echo "Memory cleared."
  exit 0
fi

case "$PROMPT" in
  remember:*)
    MEMORY_TEXT="$(printf '%s\n' "$PROMPT" | sed 's/^remember:[[:space:]]*//')"
    [ -n "$MEMORY_TEXT" ] || die "Nothing to remember."
    printf '%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$MEMORY_TEXT" >> "$MEMORY_FILE"
    echo "Remembered: $MEMORY_TEXT"
    exit 0
    ;;
esac

if [ "$UPDATE_MODE" -eq 1 ] && [ -z "$UPDATE_FILE" ]; then
  UPDATE_FILE="$FIRST_FILE"
fi

UPDATE_TARGET_EXISTS=1
if [ "$UPDATE_MODE" -eq 1 ]; then
  [ "$STREAM" -eq 0 ] || die "--stream cannot be used with --update-file."
  [ "$JSON_OUTPUT" -eq 0 ] || die "--json cannot be used with --update-file."
  require_command basename
  require_command patch
  [ -n "$UPDATE_FILE" ] || die "--update-file needs at least one -f file, or use --update FILE."

  if [ -e "$UPDATE_FILE" ]; then
    validate_input_file "$UPDATE_FILE" "$UPDATE_FILE"
  else
    UPDATE_TARGET_EXISTS=0
    validate_new_update_target "$UPDATE_FILE"
  fi
fi

STDIN_TEXT=""
STDIN_TMP=""

if [ ! -t 0 ]; then
  STDIN_TMP="$(mktemp "${TMPDIR:-/tmp}/askgpt.stdin.XXXXXX")" || die "Could not create temporary stdin file."
  trap 'rm -f "$STDIN_TMP" "$RESPONSE_TMP" "$ANSWER_TMP" "$PAYLOAD_TMP" "$EXPLANATION_TMP" "$DIFF_TMP"' EXIT HUP INT TERM
  cat > "$STDIN_TMP"
  validate_input_file "$STDIN_TMP" "STDIN"
  STDIN_TEXT="$(redact_file "$STDIN_TMP")"
fi

CONTEXT=""
ATTACHMENT_SUMMARY=""

if [ -n "$FILES" ]; then
  OLD_IFS="$IFS"
  IFS='
'
  for file in $FILES; do
    [ -z "$file" ] && continue
    if [ "$UPDATE_MODE" -eq 1 ] && [ "$file" = "$UPDATE_FILE" ] && [ "$UPDATE_TARGET_EXISTS" -eq 0 ]; then
      append_new_file_context "$file"
      ATTACHMENT_SUMMARY="${ATTACHMENT_SUMMARY}
  new file target: $file (0 bytes)"
    else
      validate_input_file "$file" "$file"
      append_file_context "$file"
      ATTACHMENT_SUMMARY="${ATTACHMENT_SUMMARY}
  file: $file ($(byte_count "$file") bytes)"
    fi
  done
  IFS="$OLD_IFS"
fi

if [ -n "$STDIN_TEXT" ]; then
  CONTEXT="${CONTEXT}

===== STDIN =====
${STDIN_TEXT}
===== END STDIN =====
"
  ATTACHMENT_SUMMARY="${ATTACHMENT_SUMMARY}
  stdin: $(byte_count "$STDIN_TMP") bytes"
fi

if [ -z "$PROMPT" ]; then
  PROMPT="Please analyse the provided content."
fi

if [ "$UPDATE_MODE" -eq 1 ]; then
  UPDATE_DIR="$(dirname "$UPDATE_FILE")"
  UPDATE_BASE="$(basename "$UPDATE_FILE")"

  SYSTEM_TEXT="${SYSTEM_TEXT}

You are helping update a local source file. Preserve the user's ability to review the conversation.
Return exactly this structure:
--- ASKGPT_EXPLANATION_START ---
Briefly explain what you changed and why. Mention important risks or follow-up manual checks.
--- ASKGPT_EXPLANATION_END ---
--- ASKGPT_DIFF_START ---
A unified diff only. The diff must update exactly one file. Use these exact diff headers:
--- a/${UPDATE_BASE}
+++ b/${UPDATE_BASE}
Use enough context for patch(1) to apply cleanly from directory: ${UPDATE_DIR}
If the target file does not exist yet, create it in the diff using /dev/null as the old file if needed, and b/${UPDATE_BASE} as the new file.
--- ASKGPT_DIFF_END ---

Do not include markdown fences around the diff. Do not edit unrelated files. Do not omit the diff markers."
fi

MEMORY_CONTEXT=""
if [ "$USE_MEMORY" -eq 1 ] && [ -s "$MEMORY_FILE" ]; then
  MEMORY_CONTEXT="$(cat "$MEMORY_FILE" | redact_text)"
fi

DEFAULT_SYSTEM_TEXT=""
if [ "$USE_SYSTEM" -eq 1 ] && [ -r "$SYSTEM_FILE" ]; then
  validate_input_file "$SYSTEM_FILE" "$SYSTEM_FILE"
  DEFAULT_SYSTEM_TEXT="$(redact_file "$SYSTEM_FILE")"
fi

FULL_INPUT="$(cat <<EOF
${DEFAULT_SYSTEM_TEXT}
${SYSTEM_TEXT}

User request:
${PROMPT}

Persistent local memory:
${MEMORY_CONTEXT}

${CONTEXT}
EOF
)"

if [ "$PREVIEW" -eq 1 ]; then
  echo "Model: $MODEL" >&2
  echo "Endpoint: $API_URL" >&2
  echo "Prompt bytes after redaction: $(printf '%s' "$FULL_INPUT" | wc -c | tr -d '[:space:]')" >&2
  if [ -n "$ATTACHMENT_SUMMARY" ]; then
    echo "Attached inputs:${ATTACHMENT_SUMMARY}" >&2
  else
    echo "Attached inputs: none" >&2
  fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
  printf '%s\n' "$FULL_INPUT"
  exit 0
fi

get_api_key

if [ -z "$OPENAI_API_KEY" ]; then
  echo "OPENAI_API_KEY is not set and no readable key file was found." >&2
  echo "Checked:" >&2
  for key_file in $OPENAI_API_KEY_FILES; do
    echo "  $key_file" >&2
  done
  exit 1
fi

PAYLOAD_TMP="$(mktemp "${TMPDIR:-/tmp}/askgpt.payload.XXXXXX")" || die "Could not create temporary payload file."
RESPONSE_TMP="$(mktemp "${TMPDIR:-/tmp}/askgpt.response.XXXXXX")" || die "Could not create temporary response file."
ANSWER_TMP="$(mktemp "${TMPDIR:-/tmp}/askgpt.answer.XXXXXX")" || die "Could not create temporary answer file."
trap 'rm -f "$STDIN_TMP" "$RESPONSE_TMP" "$ANSWER_TMP" "$PAYLOAD_TMP" "$EXPLANATION_TMP" "$DIFF_TMP"' EXIT HUP INT TERM

if [ "$STREAM" -eq 1 ]; then
  make_payload true > "$PAYLOAD_TMP"
  run_stream_request "$PAYLOAD_TMP"
  exit $?
fi

make_payload false > "$PAYLOAD_TMP"

HTTP_STATUS="$(
  curl -sS "$API_URL" \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" \
    --max-time "$CURL_TIMEOUT" \
    --retry "$CURL_RETRIES" \
    --retry-delay 1 \
    -o "$RESPONSE_TMP" \
    -w '%{http_code}' \
    -H "Authorization: Bearer ${OPENAI_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "@${PAYLOAD_TMP}"
)"

CURL_STATUS=$?

if [ "$CURL_STATUS" -ne 0 ]; then
  echo "curl failed with exit code $CURL_STATUS" >&2
  exit "$CURL_STATUS"
fi

if [ "$HTTP_STATUS" -lt 200 ] || [ "$HTTP_STATUS" -ge 300 ]; then
  print_api_error "$RESPONSE_TMP" "$HTTP_STATUS"
  exit 1
fi

if jq -e '.error' "$RESPONSE_TMP" >/dev/null 2>&1; then
  print_api_error "$RESPONSE_TMP" "$HTTP_STATUS"
  exit 1
fi

if [ "$JSON_OUTPUT" -eq 1 ]; then
  cat "$RESPONSE_TMP"
  printf '\n'
  exit 0
fi

extract_text_response < "$RESPONSE_TMP" > "$ANSWER_TMP"

if [ ! -s "$ANSWER_TMP" ]; then
  echo "Unexpected API response:" >&2
  cat "$RESPONSE_TMP" >&2
  exit 1
fi

if [ "$UPDATE_MODE" -eq 1 ]; then
  handle_update_response "$ANSWER_TMP" "$UPDATE_FILE"

  if [ -n "$SAVE_FILE" ]; then
    save_dir="$(dirname "$SAVE_FILE")"
    if [ "$save_dir" != "." ] && [ ! -d "$save_dir" ]; then
      mkdir -p "$save_dir" || die "Could not create directory for --save: $save_dir"
    fi
    cp "$ANSWER_TMP" "$SAVE_FILE" || die "Could not save response to: $SAVE_FILE"
  fi

  if [ "$COPY_OUTPUT" -eq 1 ]; then
    copy_to_clipboard "$ANSWER_TMP"
  fi

  exit 0
fi

cat "$ANSWER_TMP"

if [ -n "$SAVE_FILE" ]; then
  save_dir="$(dirname "$SAVE_FILE")"
  if [ "$save_dir" != "." ] && [ ! -d "$save_dir" ]; then
    mkdir -p "$save_dir" || die "Could not create directory for --save: $save_dir"
  fi
  cp "$ANSWER_TMP" "$SAVE_FILE" || die "Could not save response to: $SAVE_FILE"
fi

if [ "$COPY_OUTPUT" -eq 1 ]; then
  copy_to_clipboard "$ANSWER_TMP"
fi
