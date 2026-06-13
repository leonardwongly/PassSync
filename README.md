# PassSync

PassSync is a macOS-only, one-time CLI for comparing and syncing website/app login records between 1Password and Apple Passwords.

## Status

PassSync is early-stage security-sensitive software. Start with simulation and dry-runs before using `sync --apply` against real credentials.

The v1 safety posture is intentionally conservative:

- Dry-run by default.
- `sync --apply` writes an encrypted backup before any mutation.
- 1Password access goes through the official `op` CLI.
- Apple Passwords access uses macOS Security/Keychain internet-password APIs for website/app logins.
- Conflicts default to interactive/fail-closed behavior.
- Passkey-bearing records are detected and blocked because the available CLI/Keychain password APIs cannot safely migrate passkey private key material.
- TOTP secrets are synced into 1Password when available, but Apple Passwords verification-code writes are blocked because the Keychain internet-password API does not expose a safe verification-code write surface.

## What Does Not Work Yet

PassSync is not a complete password-manager migration tool. These are the current hard limits and unfinished areas.

### Blocked by Provider or Platform APIs

- **Passkeys are not migrated.** PassSync detects passkey-bearing records and blocks them. Safe migration requires provider-supported FIDO Credential Exchange or manual passkey reenrollment on each website.
- **Apple Passwords verification-code writes are not supported.** PassSync cannot safely create Apple Passwords TOTP / verification-code entries through the macOS Keychain internet-password API. 1Password-to-Apple records with TOTP are blocked by default.
- **Apple Passwords passkey export/import is not implemented.** The current Apple integration only uses Keychain internet-password APIs for website/app passwords.
- **1Password passkey export/import is not implemented.** The current 1Password integration uses `op` item JSON for login records. 1Password JSON templates are not a safe passkey migration path.
- **Apple Passwords behavior depends on local Keychain permissions and iCloud Keychain state.** PassSync can improve checks and warnings, but it cannot fully control Apple permission prompts or iCloud Keychain propagation.

### Not Built Yet

- **Restore is not implemented.** PassSync can create and validate encrypted backups, but it cannot yet restore provider state from a backup.
- **Continuous sync is not implemented.** v1 is one-time plan/apply only. It does not watch for changes or run in the background.
- **Conflict review is still basic.** The CLI can prompt per conflict during apply, and the macOS app can display plan actions, but there is no rich field-by-field merge UI yet.
- **Only website/app login records are in scope.** Secure notes, credit cards, identities, Wi-Fi passwords, SSH keys, software licenses, custom item types, and arbitrary custom fields are not synced.
- **The native macOS app is local-build only.** A SwiftUI app target exists, but signing, notarization, releases, auto-update, and installer packaging are not implemented.

### Deliberately Not Attempted

- PassSync does not scrape Passwords.app UI.
- PassSync does not dump raw passkey private key material.
- PassSync does not silently create password-only replacements for passkey records.
- PassSync does not silently drop TOTP secrets when writing to Apple Passwords unless `--allow-password-only-for-unsupported-security-material` is explicitly used.

If any item above appears in a plan as `unsupported`, PassSync should be treated as working as designed, not as having completed that part of the migration.

## Requirements

- macOS 14 or newer.
- Xcode / Swift toolchain.
- 1Password CLI (`op`) for live 1Password reads and writes.
- A signed-in macOS user account with Keychain access for live Apple Passwords reads and writes.

## Quick Start

Build and test:

```sh
swift build
swift test
```

Build the native macOS app target:

```sh
swift build --product PassSync
```

Create a local `.app` bundle:

```sh
Scripts/package_app.sh
open .build/debug/PassSync.app
```

Run a safe preflight. This checks local tool availability but does not enumerate credentials:

```sh
swift run passsync preflight
```

Run the fully offline simulator first:

```sh
swift run passsync simulate \
  --input Examples/simulation-state.json \
  --direction bidirectional \
  --vault PassSync-Test
```

When you are ready to inspect real provider state, start with a dry-run plan:

```sh
swift run passsync plan \
  --direction bidirectional \
  --truth-source 1password
```

Apply only after reviewing the plan. `--apply` writes an encrypted backup before any mutation:

```sh
swift run passsync sync \
  --direction bidirectional \
  --truth-source 1password \
  --backup-path "$HOME/.passsync/backups/first-sync.psbackup" \
  --apply
```

For non-interactive backup passphrase input:

```sh
PASSSYNC_BACKUP_PASSPHRASE='use-a-real-secret' \
swift run passsync sync \
  --direction bidirectional \
  --truth-source 1password \
  --apply
```

The executable is produced at:

```sh
.build/debug/passsync
```

The native macOS app executable is produced at:

```sh
.build/debug/PassSync
```

The local app bundle script writes:

```sh
.build/debug/PassSync.app
```

## Usage

Inspect available commands:

```sh
swift run passsync help
```

Dry-run a one-way sync from 1Password to Apple Passwords:

```sh
swift run passsync plan --direction 1p-to-apple
```

Dry-run Apple Passwords to 1Password:

```sh
swift run passsync plan --direction apple-to-1p
```

Dry-run bidirectional sync while treating 1Password as the source of truth for conflicts:

```sh
swift run passsync plan --direction bidirectional --truth-source 1password
```

Apply a reviewed plan:

```sh
swift run passsync sync --direction bidirectional --truth-source 1password --apply
```

`--apply` prompts for a backup passphrase and writes an encrypted backup before mutating anything.

## Backup

Create an encrypted backup without syncing:

```sh
swift run passsync backup --backup-path "$HOME/.passsync/backups/manual.psbackup"
```

Verify that a backup can be decrypted:

```sh
swift run passsync restore-check --backup-path "$HOME/.passsync/backups/manual.psbackup"
```

Backups include credentials visible to the 1Password CLI and macOS Keychain internet-password APIs. Provider-managed passkey private key material is not exported through those APIs.

## Simulation

Use `simulate` to test planning and apply behavior without touching 1Password, Apple Passwords, Keychain, or backups. Simulation reads a JSON state file and, with `--apply`, writes a new output state file. The input is never modified in place.

The state file shape is:

```json
{
  "onePasswordRecords": [
    {
      "provider": "1password",
      "sourceID": "onep-example",
      "vaultID": "PassSync-Test",
      "title": "Example",
      "username": "user@example.test",
      "password": "dummy-password",
      "urls": ["https://example.test/login"],
      "notes": "Synthetic only",
      "totpURI": "otpauth://totp/example:user@example.test?secret=JBSWY3DPEHPK3PXP&issuer=Example",
      "hasPasskey": false
    }
  ],
  "appleRecords": []
}
```

Dry-run the checked-in fixture:

```sh
swift run passsync simulate \
  --input Examples/simulation-state.json \
  --direction bidirectional \
  --vault PassSync-Test
```

Write a simulated output state while treating 1Password as the truth source:

```sh
swift run passsync simulate \
  --input Examples/simulation-state.json \
  --output /tmp/passsync-sim-output.json \
  --direction bidirectional \
  --truth-source 1password \
  --vault PassSync-Test \
  --apply
```

Simulation deliberately mimics v1 provider limitations:

- Apple-side simulated writes drop `totpURI`, matching the real Keychain internet-password API limitation.
- Passkey-bearing records remain unsupported and block apply.
- `--allow-password-only-for-unsupported-security-material` is required before simulation will test password-only Apple writes for TOTP-bearing records.

## Sync Directions

PassSync supports all three v1 one-time sync modes:

- `1p-to-apple`
- `apple-to-1p`
- `bidirectional`

The CLI does not continuously monitor changes. Continuous sync is intentionally left for v2.

## Conflict Handling

Default conflict behavior is `interactive`. During `sync --apply`, PassSync prompts for each conflict and lets you choose 1Password, Apple Passwords, skip, or abort. You can also choose a trust source explicitly:

```sh
--truth-source 1password
--truth-source apple-passwords
```

Or use a conflict policy:

```sh
--conflicts prefer-1password
--conflicts prefer-apple
--conflicts prefer-newest
--conflicts fail
```

`prefer-newest` only resolves conflicts when both sides expose modification timestamps.

## Passkeys

PassSync detects passkey evidence in provider records and then selects a supported transfer path. In v1, the supported transfer path is unavailable for this CLI:

- 1Password JSON templates do not support passkeys and can overwrite them during edits.
- macOS Keychain internet-password APIs handle passwords, not passkey migration.
- FIDO Credential Exchange is the right long-term shape, but provider CLI support is not yet exposed here.

Therefore v1 blocks passkey-bearing records rather than creating password-only copies that might mislead the user into thinking passkeys migrated.

Use provider-supported FIDO Credential Exchange flows, or manually create new passkeys on each website, for passkey migration.

## TOTP / Verification Codes

PassSync treats TOTP seeds as secrets:

- Secrets are redacted from JSON plans and error messages.
- Backups are encrypted.
- Apple-to-1Password TOTP writes are supported when a source record includes an `otpauth://` URI.
- 1Password-to-Apple TOTP writes are blocked because the Apple Keychain internet-password API does not safely create Passwords.app verification-code entries.

To intentionally allow password-only writes when security material cannot be transferred:

```sh
--allow-password-only-for-unsupported-security-material
```

Use that flag only after reviewing the plan.

## Future Plans

### Near Term

- **Restore flow.** Add `restore-plan` and `restore --apply` so encrypted backups can be used to recover provider-visible records.
- **Better conflict review.** Add field-level diffs, per-field merge decisions, batch actions, and reusable decision files.
- **Doctor checks.** Expand preflight into `doctor` checks for `op`, Keychain access, app bundle state, backup writability, and risky iCloud Keychain conditions.
- **Simulation examples.** Add built-in examples for minimal login, conflict, TOTP, passkey-blocked, and bidirectional migration cases.
- **Backup hardening.** Move the encrypted backup KDF from the current versioned SHA-256 iteration scheme to a standard KDF such as PBKDF2 or Argon2.

### Mid Term

- **Signed macOS app distribution.** Add signing, notarization, release packaging, and a documented install path for the SwiftUI app.
- **Richer SwiftUI workflows.** Add guided preflight, plan review, backup creation, conflict resolution, and restore screens.
- **Durable sync state.** Add a local SQLite state store for provider fingerprints, last-seen records, decisions, and audit history.
- **Expanded item audits.** Detect secure notes, credit cards, identities, Wi-Fi passwords, SSH keys, software licenses, and custom fields, then report exactly what can and cannot be migrated.
- **Manual passkey/TOTP migration guides.** Add account-level checklists for records that require provider-supported Credential Exchange or manual reenrollment.

### Longer Term

- **Continuous sync.** Add an opt-in background sync mode after restore, conflict review, and durable state are mature.
- **Credential Exchange integration.** Investigate Apple AuthenticationServices and provider-supported FIDO Credential Exchange flows for user-mediated passkey migration.
- **Credential provider extension.** Explore whether a future app/extension should provide passwords or one-time passcodes to AutoFill instead of only migrating records.
- **Release automation.** Add CI, signed builds, notarization checks, changelogs, and update distribution.

## License

PassSync is licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
