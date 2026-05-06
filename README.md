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

The package script also writes the website download artifact to
`download-site/public/downloads/Personal-Env-macOS.dmg`, which is the file used
by the production download CTA. The DMG contains `Personal Env.app` and an
`Applications` symlink for the standard drag-to-Applications install flow.

By default, packaging uses ad-hoc signing for local development. To make the DMG
pass Gatekeeper for public downloads, build with a Developer ID Application
certificate and Apple notarization credentials:

```sh
export PERSONAL_ENV_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export PERSONAL_ENV_APPLE_ID="you@example.com"
export PERSONAL_ENV_APPLE_TEAM_ID="TEAMID"
export PERSONAL_ENV_APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
PERSONAL_ENV_NOTARIZE=1 bash scripts/package-macos.sh
```

The notarized build signs the app and DMG, staples notarization, and verifies
the app signature, DMG signature, Gatekeeper assessment, and stapled ticket
before it exits. You can rerun those checks manually with:

```sh
codesign --verify --deep --strict --verbose=2 "dist/Personal Env.app"
codesign --verify --verbose=2 "download-site/public/downloads/Personal-Env-macOS.dmg"
spctl --assess --type execute --verbose=4 "dist/Personal Env.app"
spctl --assess --type open --context context:primary-signature --verbose=4 "download-site/public/downloads/Personal-Env-macOS.dmg"
xcrun stapler validate "download-site/public/downloads/Personal-Env-macOS.dmg"
```

GitHub Actions can also build the notarized DMG. Export the Developer ID
Application certificate and private key from Keychain Access as a passworded
`.p12`, base64-encode it, and add these repository secrets:

```text
APPLE_CERTIFICATE_P12_BASE64
APPLE_CERTIFICATE_PASSWORD
APPLE_KEYCHAIN_PASSWORD
PERSONAL_ENV_SIGN_IDENTITY
PERSONAL_ENV_APPLE_ID
PERSONAL_ENV_APPLE_TEAM_ID
PERSONAL_ENV_APPLE_APP_PASSWORD
```

Generate the base64 value with:

```sh
base64 -i DeveloperIDApplication.p12 | pbcopy
```

`APPLE_KEYCHAIN_PASSWORD` can be any strong random value used only for the
temporary CI keychain. Trigger the workflow from GitHub Actions with **Build
notarized DMG**, or push a `v*` tag. The workflow always uploads the notarized
DMG as an artifact. When manually triggered, set **publish_to_repo** to true to
commit the notarized DMG back to the current branch so Vercel deploys it from
`download-site/public/downloads/Personal-Env-macOS.dmg`.

This repo uses a local `post-commit` hook to keep that DMG fresh after commits:

```sh
git config --local core.hooksPath .githooks
```

The hook rebuilds the macOS app package and stages the website DMG for the next
commit if it changed.

`swift run PersonalEnv` builds/runs the SwiftPM executable, but packaging is the
normal path if you want a visible macOS app bundle with a bundle identifier.
# personal-env
