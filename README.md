# askgpt

`askgpt` is a small shell CLI for sending a question plus optional file/stdin context to the OpenAI Responses API.

## Quick Start

```sh
chmod +x askgpt.sh
./askgpt.sh "Explain rc.conf"
./askgpt.sh -f /etc/rc.conf "Explain this FreeBSD config"
tail -200 /var/log/messages | ./askgpt.sh "Summarise this log"
```

Set your API key with one of:

```sh
export OPENAI_API_KEY="sk-..."
mkdir -p "$HOME/.config/openai"
printf '%s\n' "sk-..." > "$HOME/.config/openai/api_key"
chmod 600 "$HOME/.config/openai/api_key"
```

## Useful Options

```sh
./askgpt.sh --dry-run -f config.php "Check this prompt before sending"
./askgpt.sh --preview -f index.php "Review this file"
./askgpt.sh --stream "Write a short deployment checklist"
./askgpt.sh --save answer.md -f index.php "Review this file"
./askgpt.sh --json "Return a test answer"
./askgpt.sh --no-memory "Ignore saved notes"
./askgpt.sh --max-bytes 2097152 -f large.log "Summarise this"
./askgpt.sh -f a_file.php -u "Improve the security of this file"
./askgpt.sh --update a_file.php --patch-only "Show a safer version as a patch"
./askgpt.sh -f NewClass.php -u "Create a new class called Test"
```

## Updating Files

Use `-u` or `--update-file` to ask for a patch against the first file passed with `-f`:

```sh
./askgpt.sh -f ~/a_file.php -u "Improve the security of this file"
```

Use `--update FILE` when you want to target one file while also sending extra context:

```sh
./askgpt.sh --update app.php -f config.php "Improve app.php using config.php as context"
```

Update mode keeps the conversation visible. It prints the assistant's explanation, prints the proposed unified diff, checks that the patch applies cleanly, creates a timestamped `.bak` backup, and asks before changing the file.

If the update target does not exist yet, update mode treats it as a new empty file:

```sh
./askgpt.sh -f ~/NewClass.php -u "Create a new class called Test"
./askgpt.sh --update ~/NewClass.php "Create a new class called Test"
```

Supporting context files still need to exist. For example, this creates `NewClass.php` while using `BaseModel.php` as context:

```sh
./askgpt.sh --update NewClass.php -f BaseModel.php "Create a Test class following the existing style"
```

Useful update options:

```sh
./askgpt.sh -f app.php -u --patch-only "Show the patch but do not apply it"
./askgpt.sh -f app.php -u --yes "Apply the patch without asking"
./askgpt.sh -f app.php -u --no-backup "Apply without creating a backup"
```

## Memory

```sh
./askgpt.sh remember "My preferred OS is FreeBSD"
./askgpt.sh memory
./askgpt.sh forget
```

Memory is stored locally at:

```text
$HOME/.config/openai/askgpt_memory.txt
```

You can override it with `ASKGPT_MEMORY_FILE`.

## Default Guidance

Optional default guidance can be stored in:

```text
$HOME/.config/openai/askgpt_system.txt
```

For one request, use:

```sh
./askgpt.sh --system "Answer as a concise FreeBSD administrator." "How should I inspect this?"
./askgpt.sh --system-file ./review-style.txt -f app.php "Review this"
```

Use `--no-system` to skip the default guidance file.

## Safety Features

The script:

- Redacts common secrets before sending prompts.
- Refuses binary files.
- Enforces a per-input byte limit.
- Supports `--dry-run` so you can inspect exactly what would be sent.
- Applies file updates and new-file creation as reviewable unified diffs, with a dry-run check first.
- Handles API HTTP errors and OpenAI error payloads with non-zero exits.
- Uses curl timeouts and retries for transient failures.

## Environment

```text
OPENAI_API_KEY
OPENAI_API_KEY_FILE
OPENAI_MODEL
OPENAI_API_URL
ASKGPT_MEMORY_FILE
ASKGPT_SYSTEM_FILE
ASKGPT_MAX_BYTES
ASKGPT_TIMEOUT
ASKGPT_CONNECT_TIMEOUT
ASKGPT_RETRIES
```

## Install

Copy or symlink the script somewhere on your `PATH`, for example:

```sh
mkdir -p "$HOME/bin"
ln -s "$PWD/askgpt.sh" "$HOME/bin/askgpt"
```

Then run:

```sh
askgpt --help
```
