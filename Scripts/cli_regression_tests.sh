#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BIN_DIR="${BIN_DIR:-$(swift build --show-bin-path)}"
PASSSYNC_BIN="${PASSSYNC_BIN:-$BIN_DIR/passsync}"

expect_failure() {
  local name="$1"
  local pattern="$2"
  shift 2

  local stdout_path
  local stderr_path
  stdout_path="$(mktemp)"
  stderr_path="$(mktemp)"
  trap 'rm -f "$stdout_path" "$stderr_path"' RETURN

  if "$@" >"$stdout_path" 2>"$stderr_path"; then
    echo "FAIL: $name unexpectedly succeeded" >&2
    cat "$stdout_path" >&2
    exit 1
  fi

  if ! grep -Eq "$pattern" "$stderr_path"; then
    echo "FAIL: $name stderr did not match /$pattern/" >&2
    cat "$stderr_path" >&2
    exit 1
  fi

  echo "PASS: $name"
}

expect_success() {
  local name="$1"
  local pattern="$2"
  shift 2

  local stdout_path
  local stderr_path
  stdout_path="$(mktemp)"
  stderr_path="$(mktemp)"
  trap 'rm -f "$stdout_path" "$stderr_path"' RETURN

  if ! "$@" >"$stdout_path" 2>"$stderr_path"; then
    echo "FAIL: $name unexpectedly failed" >&2
    cat "$stderr_path" >&2
    exit 1
  fi

  if ! grep -Eq "$pattern" "$stdout_path"; then
    echo "FAIL: $name stdout did not match /$pattern/" >&2
    cat "$stdout_path" >&2
    exit 1
  fi

  echo "PASS: $name"
}

mock_op="$(mktemp)"
cat >"$mock_op" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == "item list --format json --vault Private" ]]; then
  printf '[{"id":"login-1","title":"Login","category":"LOGIN"},{"id":"note-1","title":"Private Note","category":"SECURE_NOTE"},{"id":"ssh-1","title":"SSH Key","category":"SSH_KEY"}]'
else
  echo "unexpected mock op args: $*" >&2
  exit 2
fi
EOF
chmod +x "$mock_op"

expect_success \
  "item category audit" \
  "OUT-OF-SCOPE.*SECURE_NOTE|SECURE_NOTE.*OUT-OF-SCOPE" \
  "$PASSSYNC_BIN" item-audit \
    --op-path "$mock_op" \
    --vault Private

expect_failure \
  "malformed simulation input" \
  "decoding failed" \
  "$PASSSYNC_BIN" simulate \
    --input Examples/malformed-simulation-state.json \
    --direction bidirectional

expect_failure \
  "malformed decision file" \
  "decoding failed" \
  "$PASSSYNC_BIN" simulate \
    --input Examples/simulation-state.json \
    --direction bidirectional \
    --decision-file Examples/malformed-decision-file.json

expect_failure \
  "malformed backup envelope" \
  "decoding failed|unsupported" \
  env PASSSYNC_BACKUP_PASSPHRASE=cli-regression-passphrase \
    "$PASSSYNC_BIN" restore-check \
    --backup-path Examples/malformed-backup-envelope.json

help_output="$("$PASSSYNC_BIN" --help)"
if ! grep -q "TOTP-bearing records only" <<<"$help_output"; then
  echo "Expected help to describe password-only downgrade as TOTP-only." >&2
  exit 1
fi
if grep -q "TOTP/passkey material" <<<"$help_output"; then
  echo "Help must not imply passkeys can use the password-only downgrade flag." >&2
  exit 1
fi
