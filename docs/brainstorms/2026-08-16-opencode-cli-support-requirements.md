---
date: 2026-08-16
topic: opencode-cli-support
---

# Opencode CLI Support

## Summary

Install the `opencode` AI coding agent CLI in `base/Dockerfile` alongside Claude Code and GitHub Copilot CLI, with full `setup.json`-driven configuration parity — global config, skills, MCPs, and plugins — via a new `opencode_setup()` in `entrypoint.sh`.

## Problem Frame

`dev-image:base` already treats Claude Code and GitHub Copilot CLI as first-class agents: both are installed in the Dockerfile and configured through a dedicated `*_setup()` function in `entrypoint.sh`, driven by `setup.json` (global config file, skills directory, HTTP/stdio MCPs, plugins).

`opencode` is a comparable terminal AI coding agent with an equivalent configuration surface — a global `AGENTS.md`, a `skills/` directory, an `mcp` section in `opencode.json`, and a `plugins/` directory — but it is entirely absent from this repo today: not installed, not documented, not configurable via `setup.json`.

## Key Decisions

- **Full `setup.json` parity, not a binary-only install.** `opencode` gets the same configuration surface as Claude Code and Copilot CLI rather than being installed unconfigured, so all three agents behave consistently for users of this image.

## Requirements

**Packaging**
- R1. `base/Dockerfile` installs `opencode` via its official install script (`curl -fsSL https://opencode.ai/install | bash`), following the same pattern as the existing Claude CLI install step.

**Entrypoint Integration**
- R2. `entrypoint.sh` gains an `opencode_setup()` function mirroring `claude_setup()`'s structure: global `AGENTS.md`, skills directory install, HTTP MCPs, stdio MCPs, and plugins.
- R3. `opencode_setup()` is guarded by the existing `SETUP_INITIALIZED_MARKER`, consistent with `claude_setup()` and `copilot_setup()`.
- R4. `setup.json` gains an `opencode` block mirroring the existing `claude` block's schema (`global_md`, `skills_dir`, `http_mcps`, `stdio_mcps`, `plugins`).

**Documentation**
- R5. The README's `setup.json` field reference table and CLI verification section are updated to include `opencode` alongside Claude Code and GitHub Copilot CLI.

## Scope Boundaries

**Outside this scope**
- Changing the existing `claude_setup()`/`copilot_setup()` functions themselves — this brainstorm only adds a matching third function.

## Dependencies / Assumptions

- Assumes `opencode`'s config file locations and MCP/plugin mechanics (documented at [opencode.ai/docs/config](https://opencode.ai/docs/config/)) are stable enough to mirror at implementation time — worth a fresh doc check during planning, since this is an actively evolving project.

## Outstanding Questions

**Deferred to Planning**
- Exact `setup.json` schema field names for the `opencode` block (mirror `claude`'s naming, or `opencode`'s own terminology).
- Whether `opencode`'s MCP/plugin CLI commands support the same non-interactive "add" flow `claude mcp add`/`claude plugin install` do, which `entrypoint.sh` needs to drive them non-interactively.

## Sources / Research

- [Installation and Setup | sst/opencode | DeepWiki](https://deepwiki.com/sst/opencode/1.3-installation-and-setup) — confirms the install script and package name.
- [Config | OpenCode](https://opencode.ai/docs/config/) — confirms the config directory layout (`opencode.json`, `AGENTS.md`, `agents/`, `plugins/`, `skills/`) and MCP configuration shape.
