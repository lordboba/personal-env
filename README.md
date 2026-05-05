# Personal Env

Native macOS SwiftUI app for storing coding environment variables in Apple Keychain and releasing them only after device-owner authentication. iOS support is planned through the shared `PersonalEnvCore` target.

## Architecture

- `PersonalEnvCore`: Keychain persistence, LocalAuthentication unlock, and `.env` import/export.
- `PersonalEnvApp`: macOS SwiftUI app with vaults, masked variables, Touch ID/passkey unlock, import/export controls, key copy, and detail-pane editing.
- `penv`: developer CLI for creating vaults and setting/importing/exporting variables.

## Security Model

- Secrets are persisted through Apple Keychain using `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- Reads and writes go through `LocalAuthentication` with `.deviceOwnerAuthentication`, allowing Touch ID, passkey/device auth, or passcode fallback depending on hardware.
- No localhost socket is exposed. Automation should use the explicit CLI export path.

## CLI

```sh
swift run penv vault "Personal Coding" /Users/tylerxiao/Code/project
swift run penv set <vault-id> OPENAI_API_KEY sk-... ai
swift run penv import <vault-id> .env
swift run penv export <vault-id> OPENAI_API_KEY
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
