# Security Policy

PassSync handles password-manager data and should be treated as security-sensitive software. The project is still early-stage, so conservative behavior is preferred over broad migration coverage.

## Supported Versions

Only the current `main` branch is supported while the project is pre-1.0. Security fixes should be made against `main` and released from there.

## Reporting a Vulnerability

Do not open a public issue with credential data, backup files, terminal logs containing secrets, or provider exports.

Report vulnerabilities privately through GitHub private vulnerability reporting if it is enabled for the repository. If that is unavailable, contact the repository owner and include only redacted reproduction details until a private channel is established.

Useful reports include:

- PassSync version or commit.
- macOS version.
- Whether the issue affects simulation, dry-run, backup, restore, or `--apply`.
- Minimal redacted steps to reproduce.
- Whether credentials, TOTP seeds, passkey evidence, backup passphrases, or backup files may have been exposed.

## Secret Handling Expectations

- Plans and JSON output must redact passwords and TOTP seeds.
- `op` write payloads must send secrets through standard input or temporary structured input, not command-line arguments.
- Encrypted backups must not contain plaintext passwords or TOTP seeds.
- Backup passphrases must not be logged.
- Passkey-bearing records must fail closed unless a future provider-supported Credential Exchange flow is implemented.
- Apple Passwords TOTP writes must fail closed unless the user explicitly requests password-only downgrade behavior.

## Safe Testing

Prefer the offline simulator and synthetic fixtures before live provider access:

```sh
swift test
swift run passsync examples list
swift run passsync simulate --input Examples/simulation-state.json --direction bidirectional
```

For live testing, use a separate macOS user, VM, or test-only 1Password vault and make an encrypted backup before any apply. See `docs/testing.md`.

## Current Security Limits

PassSync cannot export or import passkey private key material through the current 1Password CLI JSON and macOS Keychain internet-password APIs. It also cannot create Apple Passwords verification-code entries through the Keychain internet-password API. These are treated as unsupported rather than silently downgraded.
