# Personal Env

Native macOS SwiftUI app for storing coding environment variables in Apple Keychain and releasing them only after device-owner authentication. iOS support is planned through the shared `PersonalEnvCore` target.

## Architecture

- `PersonalEnvCore`: Keychain persistence, LocalAuthentication unlock, `.env` import/export, agent token permissions, localhost API.
- `PersonalEnvApp`: macOS SwiftUI app with vaults, masked variables, Touch ID/passkey unlock, import/export/share controls, and API server status.
- `penv`: developer/agent CLI for creating vaults, setting/importing/exporting variables, issuing scoped tokens, and running the local API.

## Security Model

- Secrets are persisted through Apple Keychain using `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- Reads and writes go through `LocalAuthentication` with `.deviceOwnerAuthentication`, allowing Touch ID, passkey/device auth, or passcode fallback depending on hardware.
- Local AI agents do not get blanket access. They need a bearer token whose hash is stored in the vault state, and each token is scoped to one project path plus an allowlist of variable keys.
- The local API binds to localhost and exposes `POST /v1/inject`.

## Local Agent API

Start the API:

```sh
swift run penv serve
```

Request variables:

```sh
curl -sS http://127.0.0.1:4887/v1/inject \
  -H "Authorization: Bearer $PERSONAL_ENV_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"projectPath":"/Users/tylerxiao/Code/project","keys":["OPENAI_API_KEY"]}'
```

Response:

```json
{"variables":{"OPENAI_API_KEY":"sk-..."}}
```

## CLI

```sh
swift run penv vault "Personal Coding" /Users/tylerxiao/Code/project
swift run penv set <vault-id> OPENAI_API_KEY sk-... ai
swift run penv import <vault-id> .env
swift run penv export <vault-id> OPENAI_API_KEY
swift run penv token "Codex Local Agent" /Users/tylerxiao/Code/project OPENAI_API_KEY RESEND_API_KEY
swift run penv serve
```

## Build and Test

```sh
swift test
swift build
```

For the macOS desktop app, package and open the `.app` bundle:

```sh
bash scripts/package-macos.sh
open "dist/Personal Env.app"
```

`swift run PersonalEnv` builds/runs the SwiftPM executable, but packaging is the
normal path if you want a visible macOS app bundle with a bundle identifier.
# personal-env
