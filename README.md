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

## Roadmap

v2 candidates:

- Continuous sync with durable state and change detection.
- FIDO Credential Exchange import/export support if 1Password and Apple expose compatible local automation surfaces.
- First-class interactive conflict resolver.
- Stronger backup KDF such as PBKDF2 or Argon2.

v2/v3 candidate:

- Native SwiftUI macOS app.

## License

PassSync is licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
