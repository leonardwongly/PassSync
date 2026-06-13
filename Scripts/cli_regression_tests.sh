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
