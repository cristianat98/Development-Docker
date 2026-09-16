---
date: 2026-08-16
topic: embedded-docker-daemon
---

# Embedded Docker Daemon (Rootless)

## Summary

A new Docker-enabled image variant embeds a rootless Docker daemon, supervised in the background, so bind mounts resolve correctly against the dev container's own filesystem. `dev-image:base` (no daemon) stays untouched; a privileged/rootful build is deferred as a future sibling variant.

## Problem Frame

Today, `examples/docker-compose.yml` runs Docker as a separate `docker:dind` sidecar container (`docker-daemon`), reached via `DOCKER_HOST=tcp://docker-daemon:2375`. The dev container only has the Docker CLI installed (`docker-ce-cli`), no daemon.

This breaks bind mounts: when a developer runs `docker run -v $(pwd):/app` from inside the dev container, that path exists on the dev container's filesystem but not on the separate `docker-daemon` container's filesystem — the two containers are different filesystem namespaces. The daemon ends up mounting an empty or wrong directory instead of the intended source.

Embedding the daemon directly in the dev container fixes this structurally: client and daemon then share one filesystem, so bind-mount source paths always resolve.

## Key Decisions

- **Rootless daemon, not privileged, for this first build.** `--privileged` grants all Linux capabilities, disables seccomp/AppArmor confinement, and exposes all host devices — a compromised process could escape to full host root. This dev container runs on a single-user machine or trusted CI, so that blast radius isn't the primary constraint today, but rootless's narrower grant set (no full capability set, no arbitrary device access, seccomp mostly intact) is preferred as the default. A privileged variant is deferred as a future sibling image if rootless's limitations (below) become blocking.
- **New image variant, not baked into `dev-image:base` or toggled at runtime.** Keeps the existing lean base image unchanged for anyone who doesn't need Docker, consistent with prior image-size-reduction work (`a7e407e`). The Docker-enabled variant always runs the daemon — it is not an optional runtime toggle.
- **Supervisor manages only `dockerd`, running backgrounded.** `entrypoint.sh`'s existing contract (one-time setup, then `exec "$@"` so the container's `CMD` becomes PID 1) stays unchanged. Supervisor starts before that as a background process whose only job is keeping `dockerd` alive — no restructuring around supervisor as PID 1.
- **Standard `overlay`/`fuse-overlayfs` storage driver, not `vfs`.** `vfs` would drop the `/dev/fuse` device requirement, but at real build/pull performance and disk-usage cost (no copy-on-write between layers). Since `examples/docker-compose.yml` already pre-configures the required device and seccomp grants, that friction is a non-issue for compose users, so the performance trade isn't worth it.
- **`SETUP_INITIALIZED_MARKER`'s existing scope is preserved.** It was added in commit `d7ca40d` because re-running `claude mcp add` and `bb profile create` on restart fails outright (non-idempotent, `set -euo pipefail`). Narrowing that guard broadly would reintroduce that failure. Only the new supervisor/`dockerd` startup is added *outside* the guard, since it's a service to keep alive, not one-time setup.

## Requirements

**Image & Packaging**
- R1. A new image variant installs `dockerd`, `containerd`, and the rootless Docker extras (`docker-ce-rootless-extras`, `uidmap`) alongside the existing `docker-ce-cli`, without changing `dev-image:base`.
- R2. The new variant configures `/etc/subuid` and `/etc/subgid` entries at build time so the container's user can run rootless `dockerd` without additional runtime configuration.
- R3. The new variant's `dockerd` uses the standard `overlay`/`fuse-overlayfs` storage driver.

**Daemon Supervision**
- R4. Supervisor manages `dockerd` as a background-monitored process and restarts it if it crashes.
- R5. Supervisor starts unconditionally on every container start, independent of `SETUP_INITIALIZED_MARKER`, so a restarted container always ends up with a running daemon.
- R6. `entrypoint.sh` keeps its existing setup-then-`exec "$@"` contract; supervisor runs backgrounded, not as PID 1.

**Entrypoint Integration**
- R7. `docker_login()`'s existing daemon-reachability poll (`docker info` retry loop) continues to work against the local rootless daemon, with `DOCKER_HOST`/context adjusted to point at it instead of an external sidecar.
- R8. All existing `SETUP_INITIALIZED_MARKER`-guarded functions (`github_login`, `git_setup`, `claude_setup`, `copilot_setup`, `bitbucket_setup`, `docker_login`, `gcloud_setup`, `aws_setup`, `custom_scripts_setup`) keep their current skip-on-restart behavior unchanged.

**Documentation & Examples**
- R9. `examples/docker-compose.yml` gains a service (or variant file) demonstrating the new image, with the required `/dev/fuse` device and seccomp relaxation pre-configured under `devices:`/`security_opt:`.
- R10. The README documents the equivalent plain `docker run` flags (`--device /dev/fuse`, a seccomp relaxation) for anyone not using Compose.
- R11. The README documents rootless mode's known limitations — unenforced CPU/memory limits, slower userspace networking (`slirp4netns`), no macvlan/GPU passthrough — so users aren't surprised by them.

## Acceptance Examples

- AE1. **Covers R5.** Given a container was already initialized (`SETUP_INITIALIZED_MARKER` present) and gets restarted, when the container starts, then supervisor starts `dockerd` again even though the rest of setup is skipped.
- AE2. **Covers R9, R10.** Given the container is launched without the `/dev/fuse` device or the required seccomp relaxation, when `dockerd` attempts to start, then it fails to start and the failure is logged clearly (not a silent crash-loop) so the missing runtime flags are obvious to diagnose.

## Scope Boundaries

**Deferred for later**
- A privileged/rootful daemon variant, offered as a sibling image if rootless's resource-limit and networking-performance limitations become blocking.

**Outside this scope**
- Any change to the existing `dind`-sidecar example/workflow that `dev-image:base` users rely on today — it stays as-is.
- Making `claude_setup`/`copilot_setup`/`bitbucket_setup` idempotent — only needed if the marker guard were narrowed further than this brainstorm scopes it.

## Dependencies / Assumptions

- Whoever launches the new image variant must be able to grant `--device /dev/fuse` and a relaxed seccomp profile (or the Compose equivalents) — rootless `dockerd` cannot start without them, and the image cannot self-grant runtime device/seccomp permissions from inside.
- The container is assumed to run on a single-user machine or an isolated, trusted CI runner — the case for rootless over privileged in this brainstorm rests on that threat model, not a shared or multi-tenant host.

## Outstanding Questions

**Deferred to Planning**
- Exact image/tag naming and file layout for the new variant (new Dockerfile path, build target, or published tag).
- Exact supervisor configuration (program stanza, log rotation, restart policy specifics).
- Exact mechanism for pointing the Docker CLI at the local rootless daemon (`DOCKER_HOST` value, `docker context` switch, or the default rootless socket path).
