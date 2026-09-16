---
title: "feat: Add opencode CLI support"
type: feat
status: completed
date: 2026-08-16
origin: docs/brainstorms/2026-08-16-opencode-cli-support-requirements.md
---

# feat: Add opencode CLI support

## Summary

Install `opencode` (SST's terminal AI coding agent CLI) in `base/Dockerfile` alongside Claude Code and GitHub Copilot CLI, with full `setup.json`-driven configuration parity — global config, skills, MCPs, and plugins — achieved entirely through non-interactive means.

## Problem Frame

`dev-image:base` already treats Claude Code and GitHub Copilot CLI as first-class agents: both are installed in the Dockerfile and configured through a dedicated `*_setup()` function in `entrypoint.sh`, driven by `setup.json`. `opencode` is a comparable agent with an equivalent config surface (a global `AGENTS.md`, a `skills/` directory, an `mcp` section in `opencode.json`, a `plugin` array in the same file) but is entirely absent from this image today.

## Key Technical Decisions

- **Install via the official script**, matching the existing Claude CLI install pattern in `base/Dockerfile` (`curl -fsSL <url> | bash`).
- **MCPs and plugins are written directly into `opencode.json` via `jq`, not shelled out to `opencode mcp add`/a plugin-install command.** `opencode mcp add` is interactive-only today ([issue #18581](https://github.com/anomalyco/opencode/issues/18581) requests non-interactive support and remains open); `opencode` has no plugin marketplace or install command at all — plugins are either local files or npm package names listed directly in config. Both mechanisms are achievable non-interactively via direct config-file writes, so both stay in scope as `setup.json` fields.
- **`setup.json`'s `opencode.plugins` field is a flat list of npm package name strings**, not Claude's `{marketplace_id, plugin_id}` object shape — there's no marketplace concept to mirror. The list is written directly into `opencode.json`'s own `plugin` array.
- **`global_md` and `skills_dir` mirror `claude_setup()`'s exact mechanics** (file copy; the existing `install_skills()` helper) — these were always simple, non-interactive file operations, unaffected by the CLI limitations above.
- **`opencode_setup()` is guarded by `SETUP_INITIALIZED_MARKER`**, consistent with `claude_setup()`/`copilot_setup()` — it runs once per container lifetime, so the direct JSON writes don't need idempotent re-merge handling.
- **Writes target the global `~/.config/opencode/opencode.json`**, matching `claude_setup()`'s `--scope user` semantics, and merge additively within the `mcp`/`plugin` keys (adding entries, not replacing the whole key) rather than overwriting them outright. `opencode.json` is unlikely to already hold meaningful `mcp`/`plugin` content the first time `opencode_setup()` runs against a freshly built image — `opencode` doesn't write config until first invocation — so this is cheap, low-cost insurance rather than a scenario expected to trigger often.

## Requirements

**Packaging**
- R1. `base/Dockerfile` installs `opencode` via `curl -fsSL https://opencode.ai/install | bash`, following the existing Claude CLI install pattern.

**Entrypoint Integration**
- R2. `entrypoint.sh` gains an `opencode_setup()` function guarded by `SETUP_INITIALIZED_MARKER`, consistent with `claude_setup()`/`copilot_setup()`.
- R3. `opencode_setup()` copies the global `AGENTS.md` file when `setup.json`'s `opencode.global_md` is set, mirroring `claude_setup()`'s `CLAUDE.md` handling.
- R4. `opencode_setup()` installs skills via the existing `install_skills()` helper when `setup.json`'s `opencode.skills_dir` is set.
- R5. `opencode_setup()` writes `setup.json`'s `opencode.http_mcps` and `opencode.stdio_mcps` entries into the global `~/.config/opencode/opencode.json`'s `mcp` key via `jq`, additively — existing entries not named in `setup.json` are preserved.
- R6. `opencode_setup()` writes `setup.json`'s `opencode.plugins` (a flat list of npm package name strings) into the same `opencode.json`'s `plugin` array via `jq`, additively.

**Configuration Schema**
- R7. `base/setup.example.json` gains an `opencode` block: `global_md`, `skills_dir`, `http_mcps`, `stdio_mcps` (identical shape to `claude`'s corresponding fields), and `plugins` (a flat string array).

**Documentation**
- R8. The README's `setup.json` field reference table and CLI verification section are updated to include `opencode` alongside Claude Code and GitHub Copilot CLI.

## Acceptance Examples

- AE1. **Covers R2.** Given `setup.json` is absent, or `opencode` isn't installed, when `entrypoint.sh` reaches `opencode_setup()`, then it logs a skip and returns without error — the same behavior `claude_setup()`/`copilot_setup()` already have for a missing config file or tool.
- AE2. **Covers R5, R6.** Given `setup.json`'s `opencode` block includes `http_mcps`, `stdio_mcps`, and `plugins` entries, when `opencode_setup()` runs, then those entries appear in `opencode.json`'s `mcp` and `plugin` keys with no prompts and no error.

## Implementation Units

### U1. Install opencode CLI in `base/Dockerfile`

**Goal:** Add `opencode` to the image via its official install script.

**Requirements:** R1

**Dependencies:** none

**Files:**
- `base/Dockerfile`

**Approach:** Add a new banner-commented `RUN` section following the existing "Claude CLI"/"GitHub Copilot CLI" sections' shell-installer pattern.

**Patterns to follow:** `base/Dockerfile`'s existing "Claude CLI" section (`curl -fsSL ... | bash`).

**Test scenarios:**
- Happy path: `docker build` succeeds and `opencode` is on `PATH` in the resulting image.

**Verification:** `docker run --rm <image> opencode --version` (or equivalent) succeeds.

---

### U2. `opencode_setup()` — global config and skills

**Goal:** Add the function skeleton (marker-guarded, config/tool presence checks) plus `global_md` and `skills_dir` handling.

**Requirements:** R2, R3, R4

**Dependencies:** U1

**Files:**
- `base/entrypoint.sh`

**Approach:** Mirror `claude_setup()`'s structure exactly for the config-file-absent guard, the `command -v opencode` guard, the `global_md` file copy (to `opencode`'s global `AGENTS.md` location), and the `skills_dir` handling via the existing `install_skills()` helper — same call shape as `claude_setup()`'s, with `"opencode"` as the agent label and the correct target directory.

**Patterns to follow:** `base/entrypoint.sh`'s `claude_setup()` function (config/tool guards, `global_md`, `skills_dir` handling) and the shared `install_skills()` helper.

**Test scenarios:**
- Happy path: with `setup.json`'s `opencode` block set and `opencode` installed, `global_md` is copied to the correct `AGENTS.md` location and `skills_dir` contents appear under `opencode`'s skills directory.
- Skip path: **Covers AE1.** With `setup.json` absent, or `opencode` not installed, `opencode_setup()` logs a skip and returns without error.

**Verification:** Run the setup flow against a test `setup.json`/`files_dir` and confirm the target files land in the expected `opencode` config locations; run it again with `setup.json` removed and confirm no errors and a skip log line.

---

### U3. `opencode_setup()` — MCPs and plugins via direct `opencode.json` writes

**Goal:** Add the `http_mcps`/`stdio_mcps`/`plugins` handling, writing directly into `opencode.json` via `jq`.

**Requirements:** R5, R6

**Dependencies:** U2

**Files:**
- `base/entrypoint.sh`

**Approach:** If `~/.config/opencode/opencode.json` doesn't exist yet, initialize it as `{}` before merging. For each `http_mcps`/`stdio_mcps` entry in `setup.json`'s `opencode` block, merge a corresponding entry into `opencode.json`'s `mcp` key (`type: "remote"` for http, `type: "local"` with a split command array for stdio) via `jq`, adding to the `mcp` object (`.mcp += {"<name>": {...}}` per entry) rather than replacing it outright, so any MCP server already present under a name not listed in `setup.json` survives. For `plugins`, append the flat string list into `opencode.json`'s `plugin` array the same way (append and de-duplicate, not replace).

**Patterns to follow:** `claude_setup()`'s `http_mcps`/`stdio_mcps`/`plugins` loop structure (reading array length via `jq`, iterating with `seq`) for the `setup.json`-reading shape; the write side is new since `opencode` has no non-interactive add command to shell out to.

**Test scenarios:**
- Happy path: **Covers AE2.** With `setup.json`'s `opencode` block specifying one `http_mcp`, one `stdio_mcp`, and two plugin package names, `opencode_setup()` results in `opencode.json` containing matching entries under `mcp` and `plugin`, with no prompts and no error.
- Edge case: an existing `opencode.json` with unrelated top-level keys, and with `mcp`/`plugin` entries not mentioned in `setup.json`, is not clobbered — those entries and keys are still present after `opencode_setup()` runs, alongside the newly added ones.

**Verification:** Inspect the resulting `opencode.json` after running `opencode_setup()` against a test `setup.json` and confirm the `mcp`/`plugin` entries match what was configured, and any pre-existing unrelated keys or entries survive the merge.

---

### U4. Update `setup.example.json` and README

**Goal:** Document the new `opencode` block and update the CLI reference table.

**Requirements:** R7, R8

**Dependencies:** U3

**Files:**
- `base/setup.example.json`
- `README.md`

**Approach:** Add the `opencode` block to `setup.example.json` matching the confirmed shape (`global_md`, `skills_dir`, `http_mcps`, `stdio_mcps` identical to `claude`'s; `plugins` as a flat string array). Update the README's `setup.json` field reference table and CLI verification section to include `opencode`.

**Test expectation:** none — documentation/example-only change.

## Scope Boundaries

**Deferred for later**
- Local-file-based `opencode` plugins (copying custom `.js`/`.ts` files into the plugins directory, similar to how skills work) — this plan covers only the npm-package-array mechanism.

**Outside this scope**
- Changing `claude_setup()`/`copilot_setup()` themselves — this plan only adds a matching third function.

## Risks & Dependencies

- **`opencode`'s CLI and config surface is young and actively evolving.** The exact `opencode.json` schema for the `mcp`/`plugin` keys should be re-verified against current docs immediately before implementing U3, not just at plan-research time — a draft v2 config spec in the `opencode` repo proposes a nested `mcp.servers.<name>` shape in place of today's flat `mcp.<name>` shape, so the jq merge path in U3 may need to target a different key structure by the time this is built.
- **Non-interactive MCP-add support may ship in a future `opencode` release** (tracked in [issue #18581](https://github.com/anomalyco/opencode/issues/18581)). If it does, the direct-JSON-write approach here could later be replaced with a CLI shell-out matching `claude_setup()`'s pattern — not needed now.

## Sources / Research

- `base/entrypoint.sh:136-206` (`claude_setup()`) — the pattern being mirrored for config/tool guards, `global_md`, `skills_dir`, and the MCP/plugin loop shape.
- [Installation and Setup | sst/opencode | DeepWiki](https://deepwiki.com/sst/opencode/1.3-installation-and-setup) — install script and package name.
- [Config | OpenCode](https://opencode.ai/docs/config/) — config directory layout and `mcp` configuration shape.
- [Issue #18581 — Add non-interactive mode for opencode mcp add](https://github.com/anomalyco/opencode/issues/18581) — confirms `opencode mcp add` is interactive-only today.
- OpenCode plugin documentation — confirms no marketplace or install command exists; plugins are local files or npm package names listed in config.
