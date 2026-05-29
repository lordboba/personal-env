# Personal Env Standard

Personal Env is a local-first contract for storing, approving, and transferring developer environment variables without asking agents or shell scripts to handle raw secrets by default.

## Vault Metadata

- A vault identifies one local project by stable `id`, display `name`, `projectPath`, optional tracked `dotenvFileName`, and `updatedAt`.
- Variable metadata contains `id`, `key`, `scope`, and `updatedAt`. Metadata caches must redact `value`.
- Secret records live only in the secure state store and include the secret value plus a fingerprint for duplicate detection.
- Project usage records link a project path, dotenv file name, key, and secret id so imports and tracked dotenv updates remain auditable without storing secret values in metadata.

## Dotenv Semantics

- Imports accept standard `KEY=value` and `export KEY=value` assignments.
- Invalid keys are rejected. Keys must use letters, numbers, and underscores and cannot start with a number.
- Existing unmanaged lines and comments are preserved when Personal Env patches a tracked dotenv file.
- Deleting or renaming a managed key removes the old managed assignment without rewriting unrelated content.
- Exports write directly to a destination file with owner-only permissions when used for automation.

## Approval Scopes

An approval subject is exact and redacted:

- `capability`: read or write.
- `vaultID`: optional exact vault id.
- `keySet`: optional exact sorted key set.
- `destination`: optional file, stdout, clipboard, or app destination.
- `requester`: optional caller identity such as `agent:codex`.
- `command`: optional operation name such as `export`.
- `expiry`: required TTL on every grant.

Scoped agent transfers must match the approved subject exactly. A broad write approval can authorize broad reads, but it does not authorize a different scoped destination or key set.

## CLI Guarantees

- `penv set` does not accept secret values as positional arguments. Use `--stdin`, `--prompt`, or `--editor`.
- `penv export` refuses implicit stdout. Use `--to-file` for automation or `--stdout --allow-secret-stdout` for an explicit human escape hatch.
- File export prints a receipt with vault, target path, and key names only. It does not print secret values.
- `penv approve` can grant scoped read/write approvals with vault, key, destination, requester, command, and TTL fields.
- `penv approvals` lists active grants with expiry.
- `penv revoke` clears active grants.

## Examples

Import a project dotenv file:

```sh
penv vault "API" /Users/you/Code/api
penv import <vault-id> /Users/you/Code/api/.env
```

Set a secret without placing it in shell history:

```sh
printf '%s' "$OPENAI_API_KEY" | penv set <vault-id> OPENAI_API_KEY --stdin --scope ai
penv set <vault-id> RESEND_API_KEY --prompt --scope email
penv set <vault-id> STRIPE_SECRET_KEY --editor --scope payments
```

Approve and perform an agent-mediated file transfer:

```sh
penv approve read \
  --ttl 10m \
  --vault <vault-id> \
  --keys OPENAI_API_KEY,RESEND_API_KEY \
  --to-file /Users/you/Code/app/.env \
  --requester agent:codex \
  --command export

penv export <vault-id> \
  --to-file /Users/you/Code/app/.env \
  --requester agent:codex \
  OPENAI_API_KEY RESEND_API_KEY
```

Use stdout only when the receiving process is intentionally trusted:

```sh
penv export <vault-id> --stdout --allow-secret-stdout OPENAI_API_KEY
```

## Dangerous Escape Hatches

Stdout and clipboard are intentionally treated as escape hatches because they expose secret material outside Personal Env's file broker. Future full-access or permission-skipping modes must stay explicit, named as dangerous, and visibly discouraged in CLI help and UI copy.
