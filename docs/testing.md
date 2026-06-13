# Testing Guide

Use the safest test level that answers the question. Simulation should be the default until you need to validate provider-specific behavior.

## Level 0: Offline Unit Tests

Runs without 1Password, Apple Passwords, Keychain mutation, or real credentials:

```sh
swift test
```

This covers planning, simulation, redaction, backup encryption, restore planning, restore verification, URL matching, and 1Password command construction.

## Level 1: Offline CLI Simulation

List the synthetic examples:

```sh
swift run passsync examples list
```

Inspect one example without running a plan:

```sh
swift run passsync examples show conflict
```

Dry-run a simulated plan:

```sh
swift run passsync simulate \
  --input Examples/simulation-state.json \
  --direction bidirectional \
  --vault PassSync-Test
```

Apply inside the simulator only:

```sh
swift run passsync simulate \
  --input Examples/simulation-state.json \
  --output /tmp/passsync-sim-output.json \
  --direction bidirectional \
  --truth-source 1password \
  --vault PassSync-Test \
  --apply
```

The simulator writes only the output JSON file. It does not touch 1Password, Apple Passwords, Keychain, or backup directories.

Export and re-read a decision file offline:

```sh
swift run passsync simulate \
  --input Examples/simulation-state.json \
  --direction bidirectional \
  --vault PassSync-Test \
  --output /tmp/passsync-sim-decisions.json

swift run passsync simulate \
  --input Examples/simulation-state.json \
  --direction bidirectional \
  --vault PassSync-Test \
  --decision-file /tmp/passsync-sim-decisions.json
```

Decision files are redacted. They are intended to capture review choices, not credential values.

## Level 2: Local Readiness Checks

Run preflight for basic tool availability:

```sh
swift run passsync preflight
```

Run doctor for deeper local checks:

```sh
APP_PATH="$(Scripts/package_app.sh)"
swift run passsync doctor \
  --backup-path "$HOME/.passsync/backups/doctor-probe.psbackup" \
  --app-bundle "$APP_PATH"
```

Doctor may inspect local tool authentication, backup-path writability, app metadata, and known unsupported security material policies. It should not sync credentials.

## Level 3: Isolated Live Dry-Run

Use a dedicated 1Password test vault and a separate macOS user account or VM when possible.

Recommended setup:

- Create a 1Password vault named `PassSync-Test`.
- Add only synthetic logins.
- Use domains under `.example.test`.
- Use dummy passwords only.
- Do not add real passkeys or real TOTP seeds.
- If testing Apple Passwords, use an isolated macOS user or VM so Passwords.app and iCloud Keychain state are not your primary account.

Dry-run live provider state:

```sh
swift run passsync plan \
  --direction bidirectional \
  --truth-source 1password \
  --vault PassSync-Test
```

Review every action before applying.

## Level 4: Isolated Live Apply

Make a standalone encrypted backup first:

```sh
PASSSYNC_BACKUP_PASSPHRASE='use-a-test-only-passphrase' \
swift run passsync backup \
  --backup-path "$HOME/.passsync/backups/pre-apply-test.psbackup" \
  --vault PassSync-Test
```

Verify the backup decrypts:

```sh
PASSSYNC_BACKUP_PASSPHRASE='use-a-test-only-passphrase' \
swift run passsync restore-check \
  --backup-path "$HOME/.passsync/backups/pre-apply-test.psbackup"
```

Inventory backups without decrypting them:

```sh
swift run passsync backup-list --backup-path "$HOME/.passsync/backups"
```

Apply only in the isolated environment:

```sh
PASSSYNC_BACKUP_PASSPHRASE='use-a-test-only-passphrase' \
swift run passsync sync \
  --direction bidirectional \
  --truth-source 1password \
  --vault PassSync-Test \
  --backup-path "$HOME/.passsync/backups/sync-apply-test.psbackup" \
  --apply
```

Verify provider state against the backup when testing restore outcomes:

```sh
PASSSYNC_BACKUP_PASSPHRASE='use-a-test-only-passphrase' \
swift run passsync restore-verify \
  --backup-path "$HOME/.passsync/backups/pre-apply-test.psbackup" \
  --to 1password \
  --vault PassSync-Test
```

`restore-verify` exits non-zero if backup records are missing, different, unsupported, or otherwise not restored in the target provider.

Successful apply commands write non-secret receipts under `~/.passsync/audit`. Inspect those receipts after isolated live apply to confirm the backup path, action count, and post-apply verification summary.

## Backup Migration Test

Rewrite a backup with the current backup envelope:

```sh
PASSSYNC_BACKUP_PASSPHRASE='use-a-test-only-passphrase' \
swift run passsync backup-migrate \
  --input "$HOME/.passsync/backups/old.psbackup" \
  --output "$HOME/.passsync/backups/migrated.psbackup"
```

The input and output paths must be different. The output is written with the current AES-GCM and PBKDF2-HMAC-SHA256 envelope.

## Release Validation

Run these before publishing a release or asking users to test:

```sh
swift test
swift build --product passsync
swift build --product PassSyncApp
APP_PATH="$(Scripts/package_app.sh)"
plutil -lint "$APP_PATH/Contents/Info.plist"
BIN_DIR="$(swift build --show-bin-path)"
"$BIN_DIR/passsync" version
"$BIN_DIR/passsync" examples list
"$BIN_DIR/passsync" examples show minimal > /tmp/passsync-minimal.json
jq empty /tmp/passsync-minimal.json
"$BIN_DIR/passsync" simulate --input Examples/simulation-state.json --direction bidirectional --output /tmp/passsync-sim-decisions.json
jq empty /tmp/passsync-sim-decisions.json
"$BIN_DIR/passsync" backup-list --backup-path /tmp/passsync-empty-backups
mkdir -p /tmp/passsync-empty-audit
"$BIN_DIR/passsync" audit-list --input /tmp/passsync-empty-audit
Scripts/package_release.sh /tmp/passsync-release-artifacts
```

Release artifacts created by `Scripts/package_release.sh` are unsigned. Treat them as local test artifacts until Developer ID signing, hardened runtime, notarization, and stapling are configured.

Do not include real credentials, real TOTP seeds, backup passphrases, or backup files in issues, screenshots, examples, or CI artifacts.
