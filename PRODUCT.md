# Personal Env Product Context

register: product

Personal Env is a native macOS utility for developers who manage environment variables across local coding projects. It stores secrets in Apple Keychain, requires device-owner authentication before access, and keeps project `.env` files easier to inspect, import, export, and update.

The primary user is a developer working across several local repos who wants less secret sprawl without introducing a hosted secrets manager. The app should feel local, private, and precise: closer to a focused macOS developer tool than a cloud dashboard.

Core workflows:

- Unlock the vault with device authentication.
- On first run, approve a folder and deep scan it for existing `.env` files before creating vaults.
- Create a fresh project vault with an empty `.env`.
- Upload an existing project or approved directory and scan for `.env` and `.env.local`.
- Review masked variables, copy a key or value, edit deliberately, and export when needed.

Design principles:

- Security should feel calm and legible, not alarming.
- Keep create-new-project and upload-existing-project as distinct actions.
- Require explicit approval before scanning broad folders like Documents or Downloads.
- Preserve native SwiftUI conventions where they help speed and trust.
- Favor dense, scannable information over marketing-style explanation.
- Use restrained color for state, selection, and primary actions only.
