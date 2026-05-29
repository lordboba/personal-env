## Agent Instructions

You (the agent) and I (developer) are building personal-env. The goal is to create a service 
for a developer like me to improve their environment variable management with a better visual 
interface to import/export and expose a agent focused CLI to securely broker the generation (still in progress on the concept) and transfer of environment variables between projects.

## UI/UX Priorities
The first and foremost priority for UI and UX should be ease of use and clear interfaces. The UI is intended to be lightweight, minimal, and similar to 1Password and Apple's Password Manager except for the purpose of storing and brokering environment variables.

## CLI/Storage Priorities
One of the top priorities of this codebase and design is security. Environment variables are stored in .env files, and the central hub all of all environment variables brokered by this MacOS app and CLI is stored in Apple's secure Keychain (and the Windows equivalent when the Windows version is made). To access files or broker via CLI, the user is required to give approval via Touch ID or password. I'm exploring building a --dangerously-skip-permissions/full-access mode for those who like living life a bit more on the edge, but that is a later feature (and there will be warnings against that).

## User Adoption/Distribution
The goal of this is project is to provide an open source and common standard among developers to use to broker, create, and securely use environment variables. I hope to keep the core principle of security (encryption and storage in KeyChain) while also eliminating the friction of switching projects, and providing a clean user interface.
