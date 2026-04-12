# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly.

**Do not open a public issue.**

Instead, email the maintainers directly. We will acknowledge receipt within 48
hours and aim to provide a fix or mitigation plan within 7 days.

## Scope

DraftFrame is a macOS terminal application that launches and manages Claude Code
sessions. Security-relevant areas include:

- PTY/terminal handling
- Git worktree operations
- Session persistence and file I/O
- Voice transcription (on-device only, no network calls)
