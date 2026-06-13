# Threat Model

PassSync is a local macOS migration assistant for one-time website/app login comparison, backup, restore, and sync between 1Password and Apple Passwords.

## Assets

- Website/app login usernames, passwords, URLs, notes, and metadata.
- TOTP seeds represented as `otpauth://` URIs.
- Passkey evidence flags and metadata.
- Encrypted backup files.
- Backup passphrases.
- 1Password CLI account/session access.
- macOS Keychain internet-password access.
- Planned decisions and conflict-resolution choices.

## Trust Boundaries

- **Local process boundary:** PassSync runs as the current macOS user and inherits that user's local permissions.
- **1Password boundary:** 1Password reads/writes go through the installed `op` CLI and whatever account/session is active there.
- **Apple boundary:** Apple Passwords reads/writes go through macOS Security/Keychain internet-password APIs and local Keychain permissions.
- **Backup boundary:** Backup files are encrypted locally; their security depends on passphrase strength, KDF cost, file permissions, and endpoint security.
- **Simulation boundary:** Simulation fixtures are synthetic and should not contain real credentials.

## In Scope

- Accidental secret disclosure through CLI output, JSON plans, tests, logs, or process arguments.
- Unsafe password-only downgrade when passkeys or TOTP seeds cannot be transferred.
- Apply without an encrypted backup.
- Restore without clear mismatch detection.
- Corrupt or malformed backup handling.
- Confusing dry-run vs apply behavior.
- Local test practices that might mutate a primary password store.

## Out of Scope

- Malware or another local process running as the same user.
- Compromised 1Password account, `op` binary, macOS Keychain, iCloud Keychain, or operating system.
- Provider-side bugs or undocumented provider data loss.
- Passkey private-key extraction through unsupported APIs.
- Network attackers, because PassSync does not provide a network service.

## Main Threats and Controls

| Threat | Control |
|---|---|
| Secrets printed in plans or JSON output | `SecretRedactor` redacts passwords and TOTP URIs; tests assert redaction. |
| Secrets exposed through process lists | 1Password write payloads are sent through stdin rather than command arguments; tests cover this path. |
| Apply destroys recoverable state | `sync --apply` and `restore --apply` write encrypted backups before mutation. |
| Weak or legacy backup encryption | New backups use AES-GCM with PBKDF2-HMAC-SHA256; legacy backups remain readable and can be migrated with `backup-migrate`. |
| Passkey records become misleading password-only records | Passkey-bearing records are unsupported and block apply. |
| TOTP seeds are silently dropped when writing Apple Passwords | Apple-destination TOTP records block by default and require explicit password-only downgrade. |
| Restore appears complete when provider state differs | `restore-verify` compares current provider records with backup records and reports pass/warn/fail. |
| Live testing mutates personal credentials | `simulate`, examples, dry-runs, `doctor`, and testing docs provide non-mutating paths first. |

## Security Invariants

- No live provider mutation without an explicit `--apply`.
- Every apply path writes an encrypted backup before mutation.
- Unsupported passkey material blocks apply.
- Apple Passwords TOTP writes block unless the user explicitly allows password-only downgrade.
- Human-readable and JSON plans redact secret values.
- Backup passphrases are not echoed or logged.

## Known Residual Risks

- The CLI cannot guarantee that Passwords.app and iCloud Keychain have fully synced after a Keychain API write.
- Restore applies provider-visible website/app login records only; it cannot restore passkey private key material or Apple verification-code entries.
- PBKDF2 cost is fixed in code today. Future releases should make KDF policy easier to audit and migrate.
- There is no durable audit-log database yet. Terminal output and backup files are the current evidence trail.
- Conflict choices are still per-record in the CLI; per-field decision files are future work.
