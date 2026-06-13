# PassSync

[![CI](https://github.com/leonardwongly/PassSync/actions/workflows/ci.yml/badge.svg)](https://github.com/leonardwongly/PassSync/actions/workflows/ci.yml)

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
- Encrypted backups use AES-GCM with PBKDF2-HMAC-SHA256 key derivation. Older PassSync backups using the v1 SHA-256 iteration envelope remain readable.
- `restore-verify` compares current provider state with a backup and exits non-zero when records are missing, different, or unsupported.
- `backup-migrate` rewrites readable backups with the current backup envelope.
- Successful `sync --apply` and `restore --apply` write non-secret hash-chained JSON receipts under `~/.passsync/audit`.
- `backup-list` inventories local `.psbackup` files without decrypting backup contents.
- `state-*` commands maintain a non-secret local SQLite metadata store for credential fingerprints, reviewed decision files, and apply receipts.

Security and validation docs:

- [Security policy](SECURITY.md)
- [Threat model](docs/threat-model.md)
- [Testing guide](docs/testing.md)

## What Does Not Work Yet

PassSync is not a complete password-manager migration tool. These are the current hard limits and unfinished areas.

### Blocked by Provider or Platform APIs

- **Passkeys are not migrated.** PassSync detects passkey-bearing records and blocks them. Safe migration requires provider-supported FIDO Credential Exchange or manual passkey reenrollment on each website.
- **Apple Passwords verification-code writes are not supported.** PassSync cannot safely create Apple Passwords TOTP / verification-code entries through the macOS Keychain internet-password API. 1Password-to-Apple records with TOTP are blocked by default.
- **Apple Passwords passkey export/import is not implemented.** The current Apple integration only uses Keychain internet-password APIs for website/app passwords.
- **1Password passkey export/import is not implemented.** The current 1Password integration uses `op` item JSON for login records. 1Password JSON templates are not a safe passkey migration path.
- **Apple Passwords behavior depends on local Keychain permissions and iCloud Keychain state.** PassSync can improve checks and warnings, but it cannot fully control Apple permission prompts or iCloud Keychain propagation.

### Not Built Yet

- **Continuous sync is not implemented.** v1 is one-time plan/apply only. It does not watch for changes or run in the background.
- **The SQLite state store is metadata only.** `--record-state` and `state-*` commands can record provider-visible credential fingerprints, reviewed decision files, and apply receipts, but the sync engine does not yet use this database as a continuous-change tracker or automatic conflict resolver.
- **Field-level conflict merge is decision-file based.** The CLI and SwiftUI app can apply reviewed per-field merge decisions from JSON decision files, but the interactive CLI prompt is still per-record.
- **Only website/app login records are in sync scope.** `item-audit` can count unsupported 1Password item categories, but secure notes, credit cards, identities, Wi-Fi passwords, SSH keys, software licenses, custom item types, and arbitrary custom fields are not synced.
- **The native macOS app is local-build only.** A SwiftUI app target exists and unsigned release archives can be created locally, but Developer ID signing, notarization, auto-update, and installer packaging are not implemented.
- **Release artifacts are unsigned.** `Scripts/package_release.sh` creates local unsigned archives with checksums. Public distribution still requires Developer ID signing and notarization.
- **Restore is provider-visible login recovery only.** Restore can plan/apply backed-up website/app login records for one provider at a time. It still blocks passkey evidence and Apple-destination TOTP unless explicitly allowed as password-only.
- **Restore verification is provider-visible only.** `restore-verify` checks backed-up website/app login records against the selected provider, but it cannot prove passkey private key material, Apple verification-code entries, or iCloud Keychain propagation.
- **Audit receipts are tamper-evident, not tamper-proof.** Receipts are local JSON files for operator evidence. New receipts include the previous receipt SHA-256 and `audit-list` reports file hashes, but receipts are not signed, notarized, append-only, or stored in a hardened database.

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
swift build --product PassSyncApp
```

Create a local `.app` bundle:

```sh
Scripts/package_app.sh
```

The packaging script prints the generated `.app` path. Open that path in Finder or with `open`.

Run a safe preflight. This checks local tool availability but does not enumerate credentials:

```sh
swift run passsync preflight
```

Run deeper local readiness checks:

```sh
APP_PATH="$(Scripts/package_app.sh)"
swift run passsync doctor \
  --backup-path "$HOME/.passsync/backups/doctor-probe.psbackup" \
  --audit-path "$HOME/.passsync/audit" \
  --app-bundle "$APP_PATH" \
  --release-script Scripts/package_release.sh
```

See [docs/testing.md](docs/testing.md) for a staged testing path from offline fixtures to isolated live apply.

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

Find the CLI executable path with:

```sh
echo "$(swift build --show-bin-path)/passsync"
```

Find the native macOS app executable path with:

```sh
echo "$(swift build --show-bin-path)/PassSyncApp"
```

The local app bundle script writes a `PassSync.app` bundle under SwiftPM's active build output directory and prints the path:

```sh
Scripts/package_app.sh
```

## Usage

Inspect available commands:

```sh
swift run passsync help
swift run passsync version
```

List and inspect offline examples:

```sh
swift run passsync examples list
swift run passsync examples show conflict
swift run passsync examples write bidirectional --output /tmp/passsync-bidirectional.json
```

The `Examples/malformed-*.json` files are intentional negative fixtures used by tests for parser and fail-closed error handling. Do not use them as simulation inputs except when testing failures.

Audit 1Password item categories without fetching item details:

```sh
swift run passsync item-audit --vault Private
```

`item-audit` reports counts by category. It treats `LOGIN` as v1 sync scope and reports other categories such as secure notes, credit cards, identities, SSH keys, and software licenses as out of scope.

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

## Decision Files

Decision files let you export a redacted plan, edit conflict decisions, and apply those decisions to a freshly rebuilt plan. Decision files do not contain passwords or TOTP seeds.

Export a live decision file without applying:

```sh
swift run passsync plan \
  --direction bidirectional \
  --truth-source 1password \
  --output /tmp/passsync-decisions.json
```

Use an edited decision file during a dry run:

```sh
swift run passsync plan \
  --direction bidirectional \
  --decision-file /tmp/passsync-decisions.json
```

Apply only after reviewing the decision-adjusted plan:

```sh
swift run passsync sync \
  --direction bidirectional \
  --decision-file /tmp/passsync-decisions.json \
  --backup-path "$HOME/.passsync/backups/reviewed-sync.psbackup" \
  --apply
```

Valid decision values are `applyOriginal`, `skip`, `useOnePassword`, `useApplePasswords`, and `mergeFields`. For `mergeFields`, each changed field except `modifiedAt` must have a provider choice in `fieldDecisions`.

The SwiftUI app can also load, edit, save, and apply decision files from the Conflict Review screen. Apply decisions to the selected simulation, live, or restore plan, then review the adjusted plan before using the relevant apply button.

## Backup

Create an encrypted backup without syncing:

```sh
swift run passsync backup --backup-path "$HOME/.passsync/backups/manual.psbackup"
```

Verify that a backup can be decrypted:

```sh
swift run passsync restore-check --backup-path "$HOME/.passsync/backups/manual.psbackup"
```

Rewrite a readable backup with the current AES-GCM and PBKDF2-HMAC-SHA256 envelope:

```sh
swift run passsync backup-migrate \
  --input "$HOME/.passsync/backups/old.psbackup" \
  --output "$HOME/.passsync/backups/migrated.psbackup"
```

List known local backups without decrypting them:

```sh
swift run passsync backup-list --backup-path "$HOME/.passsync/backups"
```

Backups include credentials visible to the 1Password CLI and macOS Keychain internet-password APIs. Provider-managed passkey private key material is not exported through those APIs.

Plan a restore from backup without mutating anything:

```sh
swift run passsync restore-plan \
  --backup-path "$HOME/.passsync/backups/manual.psbackup" \
  --to 1password
```

Verify current provider state against a backup:

```sh
swift run passsync restore-verify \
  --backup-path "$HOME/.passsync/backups/manual.psbackup" \
  --to 1password
```

`restore-verify` exits non-zero when backed-up records are missing, different, unsupported, or otherwise not restored in the target provider.

Apply a reviewed restore plan:

```sh
swift run passsync restore \
  --backup-path "$HOME/.passsync/backups/manual.psbackup" \
  --to 1password \
  --apply
```

Restore apply creates a second pre-restore encrypted backup of the current target provider state before mutating anything.

Successful sync and restore applies write a local receipt under:

```sh
$HOME/.passsync/audit
```

Receipts include action keys, action kinds, backup paths, post-apply verification summaries, and the previous receipt SHA-256 when an earlier receipt exists in the same audit directory. They do not include passwords or TOTP seeds.

List local receipts and their SHA-256 hashes:

```sh
swift run passsync audit-list --input "$HOME/.passsync/audit"
```

Verify the local receipt hash chain:

```sh
swift run passsync audit-verify --input "$HOME/.passsync/audit"
```

The SwiftUI Recovery screen can scan both backup files and audit receipts.

## State Store

PassSync can maintain a local SQLite metadata database at:

```sh
$HOME/.passsync/state/passsync.sqlite
```

The state store is intentionally non-secret. It stores provider, host/username key, source ID, vault ID, title, URL count, TOTP/passkey booleans, modification/observation timestamps, raw provider fingerprints, decision-file hashes, and receipt hashes. It does not store passwords, TOTP seeds, notes, or backup passphrases. The SQLite database uses `PRAGMA user_version`; PassSync initializes and migrates unversioned stores to the current schema and refuses newer unsupported schemas.

Record metadata from an offline simulation fixture:

```sh
swift run passsync state-record-simulation \
  --input Examples/simulation-state.json
```

Record metadata while reviewing a simulation, live plan, or restore plan:

```sh
swift run passsync simulate \
  --input Examples/simulation-state.json \
  --direction bidirectional \
  --record-state

swift run passsync plan \
  --direction bidirectional \
  --truth-source 1password \
  --record-state
```

Record metadata from a reviewed decision file or apply receipt:

```sh
swift run passsync state-record-decision --input /tmp/passsync-decisions.json
swift run passsync state-record-receipt --input "$HOME/.passsync/audit/passsync-sync-example.receipt.json"
```

Inspect the database:

```sh
swift run passsync state-summary
swift run passsync state-list-credentials --limit 25
```

Use `--state-path /tmp/passsync-state.sqlite` for isolated tests. `--record-state` records non-secret snapshots during `plan`, `sync`, `simulate`, and `restore` workflows, plus decision-file and receipt metadata when those files are written. The state store is groundwork for safer future sync workflows; it does not enable continuous sync in v1.

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

Export a synthetic decision file from a simulation dry run:

```sh
swift run passsync simulate \
  --input Examples/simulation-state.json \
  --direction bidirectional \
  --vault PassSync-Test \
  --output /tmp/passsync-sim-decisions.json
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

Test an edited decision file in the simulator:

```sh
swift run passsync simulate \
  --input Examples/simulation-state.json \
  --direction bidirectional \
  --decision-file /tmp/passsync-sim-decisions.json
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

## Distribution

Create an unsigned local release archive:

```sh
Scripts/package_release.sh
```

The script builds release-mode CLI and app artifacts, writes `passsync-<version>-macos-unsigned.tar.gz`, and emits a `.sha256` checksum file. The archive is intentionally labeled unsigned.

Public macOS distribution still requires:

- Developer ID signing certificate.
- Hardened runtime configuration.
- Notarization and stapling.
- Release notes and upgrade guidance.
- Optional Homebrew cask or installer packaging.

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

- **SwiftUI decision workflow hardening.** Add richer validation, batch controls, and clearer warnings when a decision file does not match the current plan.
- **Restore UI hardening.** Add richer SwiftUI restore verification, restore history, and clearer pre-restore backup evidence.
- **Doctor expansion.** Add more checks for risky iCloud Keychain conditions and optional deeper provider probes.
- **State-store hardening.** Add richer migration paths as the non-secret SQLite metadata store grows toward background sync.
- **Audit hardening.** Sign receipts and make post-apply verification failures more visible.
- **Signed macOS distribution.** Add Developer ID signing, hardened runtime, notarization, stapling, and release automation.
- **Malformed-input hardening.** Continue expanding end-to-end CLI stderr/exit-code regression tests as new parser surfaces are added.

### Mid Term

- **Signed macOS app distribution.** Add notarized releases, a documented install path, and update distribution for the SwiftUI app.
- **Richer SwiftUI workflows.** Add guided backup creation, per-field conflict resolution, restore history, and safer apply confirmations.
- **Durable sync state integration.** Use the local SQLite metadata store for richer last-seen comparisons and decision history during review workflows.
- **Expanded item audits.** Add Apple-side category coverage when safe APIs are available, and add richer guidance for unsupported 1Password categories.
- **Manual passkey/TOTP migration guides.** Add account-level checklists for records that require provider-supported Credential Exchange or manual reenrollment.

### Longer Term

- **Continuous sync.** Add an opt-in background sync mode after restore, conflict review, and durable state are mature.
- **Credential Exchange integration.** Investigate Apple AuthenticationServices and provider-supported FIDO Credential Exchange flows for user-mediated passkey migration.
- **Credential provider extension.** Explore whether a future app/extension should provide passwords or one-time passcodes to AutoFill instead of only migrating records.
- **Release automation.** Add CI, signed builds, notarization checks, changelogs, and update distribution.

## License

PassSync is licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
