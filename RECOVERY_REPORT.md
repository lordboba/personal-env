# personal-env Recovery Report

## Summary

The repository was recovered on top of `51605f616c32dc40b10346cb6ee511fc5a14bd00` (`Update notarized macOS release artifacts`). The June 21 security-remediation work is present in the working tree relative to that commit, with additional pre-merge review fixes applied for requester approval matching and symlink-safe dotenv writes.

## Preserved State

A source backup was created before recovery actions:

```text
/Users/tylerxiao/Documents/personal-env-recovery-backups/personal-env-current-20260622T223156.tgz
```

The backup command skipped Git's live fsmonitor socket, which is not a tracked source file.

## Restored / Present Work

The recovery commit restored and hardened these surfaces:

- `.github/workflows/notarized-dmg.yml`
- `Sources/PersonalEnvCore/AuthService.swift`
- `Sources/PersonalEnvCore/DotenvCodec.swift`
- `Sources/PersonalEnvCore/KeychainStore.swift`
- `Sources/PersonalEnvCore/SecretValueValidator.swift`
- `Sources/PersonalEnvCore/VaultService.swift`
- `Sources/penv/PEnvCLI.swift`
- `Tests/PersonalEnvCoreTests/PersonalEnvCoreTests.swift`
- `docs/standard.md`

The recovered hardening includes exact approval matching, centralized requester binding, canonical destination paths, symlink rejection for scanned/exported/tracked dotenv files, CR/LF secret rejection, direct editor execution, protected Keychain grant metadata, owner-only metadata cache permissions, and notarized DMG workflow ordering that runs tests before signing-key import.

The external remediation artifact is also present:

```text
/tmp/codex-security-scans/personal-env/51605f6_20260617T233636Z/artifacts/fix_report.md
```

## Verification

Completed:

- Confirmed the recovery files are modified relative to `51605f6`.
- Confirmed the remediation report artifact exists.
- Ran `git status --short --branch`.
- Ran `git diff --check`.
- Ran `swift test`: passed with 55 tests and 0 failures.
- Ran a pre-merge code review pass using the requested `requesting-code-review` workflow.
- Fixed the required review findings: requester approval subject construction is centralized in core, and this report no longer contains stale blocked-tooling status.
- Added regression coverage for requester-scoped grant/export matching and symlinked export targets.

## Final State

Committed and pushed to `main`:

- The recovery commit records the recovered hardening and the pre-merge review fixes.
- This report describes the committed state rather than the earlier recovery workspace.

The working tree was clean after the final push.
