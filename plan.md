# Temporary Plan: Approved Deep `.env` Scan

## Goal

Add a first-run and manual import path that lets the user explicitly approve any directory, including `Documents` and `Downloads`, then deeply scan it for `.env` and `.env.local` files. The app must show active loading/progress while scanning and must let the user review discovered variables before importing them into Keychain-backed project vaults.

## Product Behavior

- On first launch with no vaults, the welcome flow offers direct actions: scan a folder for `.env` files, upload an existing project, or create a new project.
- Manual upload can scan any user-approved folder. Approval comes from either selecting the folder in the native folder picker or pressing the scan button for the current typed path.
- Scans are asynchronous, cancellable, and visibly buffered with progress.
- Empty results are only shown after a scan finishes, not while a scan is running.
- Import remains explicit: detected variables are grouped for review and selected before anything is written to Personal Env.

## Engineering Shape

- Replace broad-folder blocking with an explicit scan policy:
  - user-approved directories are allowed;
  - system roots and non-directories remain blocked;
  - heavy/generated folders remain skipped.
- Extend recursive scanning with progress callbacks and cancellation checks.
- Resolve project roots from common markers such as `.git`, `Package.swift`, `package.json`, `pyproject.toml`, `Cargo.toml`, and similar project files.
- Keep the existing `VaultService.importDetectedDotenvFiles` import contract.
- Keep implementation in current source files so the existing SwiftPM and Xcode target wiring stays stable.

## Verification

- Add focused core tests for approved broad-folder scanning, system-root blocking, skipped heavy directories, and project-root resolution.
- Run `swift test`.
- Run `swift build`.

