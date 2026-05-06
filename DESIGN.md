# Personal Env Design Context

Personal Env uses a restrained native macOS product system.

Theme: light-first, warm-neutral, designed for a developer at a desk in normal daylight who is moving quickly between codebases and needs secrets to feel controlled.

Colors:

- Background: tinted warm off-white, not pure white.
- Sidebar: slightly deeper warm neutral to separate navigation without a heavy border.
- Content panels: subtle neutral fills and 1px separators.
- Accent: deep teal, reserved for primary actions, selected states, unlock, and copy affordances.
- Warning/error: system red only for destructive or error states.

Typography:

- Use SF/system fonts.
- Use monospaced text only for keys, masked values, scopes, paths, and command-like data.
- Keep headings compact. This is an operational tool, not a landing page.

Components:

- Rounded rectangles should stay small to moderate, usually 8-14px.
- Avoid nested cards. Use panels, rows, dividers, and table density.
- Buttons should use native SwiftUI styles, with consistent tint and compact labels.
- Empty states should point to the next useful action.

Motion:

- Minimal native state motion only. No decorative page-load animation.
