---
title: "feat: Embed rootless Docker daemon in dev-image:base"
type: feat
status: completed
date: 2026-08-16
deepened: 2026-08-16
origin: docs/brainstorms/2026-08-16-embedded-docker-daemon-requirements.md
---

# feat: Embed rootless Docker daemon in dev-image:base

## Summary

`dev-image:base` gains a rootless Docker daemon, supervised in the background, so bind mounts resolve correctly against the container's own filesystem instead of a separate `docker:dind` sidecar. It's opt-in via `setup.json`, off by default, in the same single image (no separate variant) — existing consumers see no behavior change unless they explicitly enable it.

## Problem Frame

Today, `examples/docker-compose.yml` runs Docker as a `docker:dind` sidecar (`docker-daemon`), reached via `DOCKER_HOST=tcp://docker-daemon:2375`. `base/Dockerfile` only installs the Docker CLI. When a developer inside the dev container runs `docker run -v $(pwd):/app`, that path exists on the dev container's filesystem but not on the sidecar's — the daemon mounts an empty or wrong directory. Embedding the daemon in the same container fixes this structurally: client and daemon share one filesystem.

This plan supersedes the originating brainstorm's "separate variant image" decision — the daemon goes directly into the existing `dev-image:base` as a single image, gated behind a `setup.json` opt-in rather than a separate image or an always-on default.

## Key Technical Decisions

- **Single image, Docker opt-in via `setup.json`, off by default.** The daemon, supervisor, and their dependencies are always installed in the one published image, but supervisor only ever launches when `setup.json`'s new `docker.enabled` field is `true`. A consumer who doesn't touch that field gets byte-for-byte the same runtime behavior `dev-image:base` has today — only the image's on-disk size grows. This ships as a normal feature release, not a breaking one, since default behavior is unchanged.
- **Both the `docker:dind` sidecar and the embedded daemon remain available, as alternatives.** `examples/docker-compose.yml`'s existing sidecar is untouched. The README documents the embedded daemon as a second path to the same goal (working bind mounts), so a reader picks based on their own trade-off tolerance (sidecar: simpler, but bind-mount paths must match between the two containers; embedded: paths always resolve, but requires opting in and granting `/dev/fuse` + a seccomp relaxation).
- **Dedicated non-root account (`dockerd`) owns the daemon — not a privilege-separation boundary.** Rootless `dockerd` refuses to start as root, so a dedicated account exists solely to satisfy that requirement. It provides no real isolation from root: root already bypasses standard Unix permission checks on sockets within the same container, so `entrypoint.sh` and the developer's own `docker exec` shell reach the daemon without `sudo`. Concretely, this means daemon compromise and root compromise are equivalent in this container's threat model — the account is a run-as-user workaround, not a security control. (This assumes the container itself retains `CAP_DAC_OVERRIDE` for root; see Risks & Dependencies.)
- **The supervised command is `dockerd-rootless.sh` directly, not the setup tool.** `dockerd-rootless-setuptool.sh install` is a one-time, systemd-oriented convenience wrapper; without systemd (this container has none — Ubuntu 24.04 ships systemd as a package, but nothing in this image runs it as PID 1 or a service manager), its own guidance is to run `dockerd-rootless.sh` as the long-running process, matching the pattern used by `docker-library/docker`'s rootless entrypoint. The startup step also creates and `chmod 0700`s `XDG_RUNTIME_DIR` (`/run/user/<uid>`) for the `dockerd` account — normally provided by `pam_systemd` on login, which doesn't apply here.
- **The opt-in startup runs before `entrypoint.sh`'s one-time setup block, not after it.** `docker_login()` — one of the functions inside the `SETUP_INITIALIZED_MARKER`-guarded setup block — polls for a reachable daemon when Docker registry credentials are set. If the daemon-start step ran after that block (as originally drafted), `docker_login()` would always poll a daemon supervisor hadn't been asked to start yet, and registry login would be permanently broken whenever Docker is enabled. Placing the opt-in check and daemon-start step before the marker-guarded block fixes this ordering and also satisfies "runs on every container start, not gated by the marker" for free, since it now sits outside the guard entirely. Because `entrypoint.sh` runs under `set -euo pipefail`, both the launch step and the readiness wait handle their own failure rather than letting a non-zero exit abort the whole script — a launch failure is logged and `exec "$@"` still runs.
- **Standard `overlay`/`fuse-overlayfs` storage driver, not `vfs`.** `vfs` would avoid the `/dev/fuse` device requirement, but at real build/pull performance and disk-usage cost (no copy-on-write between layers) — not worth it since enabling Docker already requires granting `/dev/fuse` and a seccomp relaxation together.
- **Supervisor is installed via the `supervisor` apt package**, in Ubuntu 24.04's universe repo with no PPA and no debconf prompts — consistent with `base/Dockerfile`'s existing apt-first pattern. `entrypoint.sh` only invokes `supervisord` at all when Docker is enabled; supervisor's own config unconditionally autostarts the `dockerd-rootless.sh` program once `supervisord` itself is running, so there's no need for supervisor-level conditional-start logic.
- **The seccomp relaxation required to enable Docker is `unconfined` (whole-container), not a scoped custom profile — a documented trade-off, not a silent one.** `security_opt` applies to the entire container, not per-process: enabling Docker drops syscall filtering for every other tool already in this image (terraform, gcloud, aws-cli, kubectl, the developer's shell), not just `dockerd`. A narrower custom profile is possible but requires real testing effort to get right; this plan documents the blast radius explicitly (README, Risks & Dependencies) rather than silently under-scoping it, and leaves a scoped profile as future work.

## Requirements

**Image & Daemon Setup**
- R1. `base/Dockerfile` installs `dockerd`, `containerd`, `docker-ce-rootless-extras`, and `uidmap`, extending the Docker apt repository already registered for the existing `docker-ce-cli` install.
- R2. `base/Dockerfile` creates the dedicated `dockerd` account with `/etc/subuid`/`/etc/subgid` entries sized for rootless operation (at least 65,536 subordinate UIDs/GIDs).
- R3. The image's `dockerd` is configured to use the `overlay`/`fuse-overlayfs` storage driver.
- R4. `base/Dockerfile` installs the `supervisor` apt package and a program configuration for `dockerd-rootless.sh`, run as the `dockerd` account. Supervisor itself is not launched at this stage — only configured.

**Opt-In Configuration**
- R5. `setup.json` gains a `docker` block with an `enabled` field; `entrypoint.sh` reads it before deciding whether to launch `supervisord` at all. Default (field absent, or `setup.json` missing entirely) is disabled, preserving today's `dev-image:base` behavior exactly.
- R6. `base/setup.example.json` and `base/.example.env` document the new `docker.enabled` field alongside the existing `claude`/`copilot`/`git`/`scripts` blocks.

**Daemon Supervision (when enabled)**
- R7. Supervisor runs `dockerd-rootless.sh` as the `dockerd` account, with `XDG_RUNTIME_DIR` created and `chmod 0700`'d, and restarts it if it crashes.
- R8. The opt-in check and (when enabled) supervisor-start step run before `entrypoint.sh`'s one-time setup block — evaluated on every container start regardless of `SETUP_INITIALIZED_MARKER`, and completed before `docker_login()`'s poll (inside that block) ever runs.
- R9. A failure to launch supervisor itself (distinct from `dockerd` failing under supervisor's watch, which autorestart already handles) does not abort `entrypoint.sh`'s flow under `set -euo pipefail` — the container's `CMD` still becomes PID 1 either way.
- R10. When Docker is enabled, a daemon-readiness wait runs immediately after the supervisor-start step, independent of whether `DOCKER_USERNAME`/`DOCKER_PASSWORD` are set.

**Entrypoint & CLI Integration**
- R11. `docker_login()`'s existing daemon-reachability poll continues to work unmodified: it reaches the local rootless daemon when Docker is enabled, or times out harmlessly exactly as it does today when it isn't.
- R12. All existing `SETUP_INITIALIZED_MARKER`-guarded functions (`github_login`, `git_setup`, `claude_setup`, `copilot_setup`, `bitbucket_setup`, `docker_login`, `gcloud_setup`, `aws_setup`, `custom_scripts_setup`) keep their current skip-on-restart behavior unchanged.

**Documentation & Examples**
- R13. `examples/docker-compose.yml`'s existing `docker:dind` sidecar stays unchanged. The README documents the embedded-daemon opt-in as an alternative path, including the `/dev/fuse` device and seccomp relaxation the `dev` service needs if a consumer enables it.
- R14. The README documents rootless mode's known limitations (unenforced CPU/memory limits, slower userspace networking, no macvlan/GPU passthrough) and names the whole-container seccomp exposure that comes with enabling Docker.

## Acceptance Examples

- AE1. **Covers R8.** Given a container was already initialized (`SETUP_INITIALIZED_MARKER` present) and gets restarted with Docker enabled, when the container starts, then supervisor starts `dockerd` again even though the rest of setup is skipped.
- AE2. **Covers R7, R13.** Given Docker is enabled but the container is launched without the `/dev/fuse` device or the required seccomp relaxation, when `dockerd` attempts to start, then it fails to start and the failure is logged clearly by supervisor (not a silent crash-loop), while the rest of the container keeps working normally.
- AE3. **Covers R9.** Given supervisor itself fails to launch (a config or permission error at supervisor's own startup, not `dockerd` failing under its watch), when `entrypoint.sh` reaches that step, then the failure is logged and `entrypoint.sh` still proceeds to `exec "$@"`.
- AE4. **Covers R10.** Given a container is started with Docker enabled but without `DOCKER_USERNAME`/`DOCKER_PASSWORD` set, when `entrypoint.sh` reaches `exec "$@"`, then the daemon-readiness wait has already run regardless of those credentials.
- AE5. **Covers R5, R11.** Given `setup.json` doesn't set `docker.enabled` (or `setup.json` is absent entirely), when the container starts, then supervisor is never launched and `entrypoint.sh` behaves exactly as `dev-image:base` does today — `docker_login()` polls and times out harmlessly if no daemon is externally reachable, precisely as it would with no changes from this plan at all.

## Implementation Units

### U1. Rootless Docker packages, dedicated account, and storage-driver config

**Goal:** Extend `base/Dockerfile` with the daemon packages, the dedicated `dockerd` account, subuid/subgid ranges, and the storage-driver configuration.

**Requirements:** R1, R2, R3

**Dependencies:** none

**Files:**
- `base/Dockerfile`

**Approach:** Extend the existing Docker apt install line (already registered against the `docker.list` keyring for `docker-ce-cli`) to add `docker-ce`, `containerd.io`, `docker-ce-rootless-extras`, and `uidmap`. Add a new banner-commented `RUN` section, following the file's existing per-tool convention, that creates the `dockerd` account with its own home directory, writes its `/etc/subuid`/`/etc/subgid` entries, and writes a `daemon.json` under that account's rootless config path pinning the storage driver.

**Patterns to follow:** `base/Dockerfile`'s existing banner-comment `RUN`-per-tool sections; the Docker CLI section's already-registered apt repo/keyring.

**Test scenarios:**
- Happy path: `docker build` succeeds and the resulting image has `dockerd`, `containerd`, and `newuidmap`/`newgidmap` on `PATH`.
- Happy path: the `dockerd` account's `/etc/subuid`/`/etc/subgid` entries are present in the built image with a range of at least 65,536.

**Verification:** Build the image and inspect it (`docker run --rm <image> id dockerd`, `docker run --rm <image> cat /etc/subuid`) to confirm the account and ranges exist.

---

### U2. Supervisor configuration for `dockerd` (installed, not launched)

**Goal:** Add a supervisor config that runs `dockerd-rootless.sh` as the `dockerd` account, with autostart and autorestart — installed into the image at build time, but not started until `entrypoint.sh` decides Docker is enabled.

**Requirements:** R4, R7

**Dependencies:** U1

**Files:**
- `base/Dockerfile` (installs `supervisor`, copies its config)
- `base/supervisord.conf` (new)

**Approach:** A supervisor program stanza runs `dockerd-rootless.sh` as the `dockerd` account, with `XDG_RUNTIME_DIR` and the rootless bin directory set in its environment, `autostart`/`autorestart` enabled (autostart applies once `supervisord` itself is running — it does not mean `supervisord` launches automatically at container start), and output routed to a log a developer can inspect from inside the container.

**Patterns to follow:** None exist in-repo yet (first supervisor usage) — follow supervisor's standard program-stanza conventions.

**Test scenarios:**
- Happy path: once `supervisord` is launched, it brings up a running `dockerd-rootless.sh` process owned by the `dockerd` account within a bounded startup window.
- Failure and recovery: killing the `dockerd` process inside a running container results in supervisor restarting it automatically.
- Failure surfacing: **Covers AE2.** Starting the container with Docker enabled but without the required `/dev/fuse` device or seccomp relaxation results in a clearly logged failure rather than a silent, unexplained crash-loop.

**Verification:** With Docker enabled, `docker exec` into a running container and confirm `docker info` succeeds against the local daemon (`DOCKER_HOST=unix:///run/user/<uid>/docker.sock`); confirm supervisor's status output shows `dockerd-rootless.sh` running under the `dockerd` account.

---

### U3. `entrypoint.sh` integration — read the opt-in, start supervisor safely and early, wait unconditionally, repoint the Docker CLI

**Goal:** Read `setup.json`'s Docker opt-in before the one-time setup block runs; when enabled, launch supervisor and wait for readiness without risking `entrypoint.sh` aborting on a supervisor-launch failure; point the Docker CLI at the local rootless daemon's socket only when enabled.

**Requirements:** R5, R6, R8, R9, R10, R11, R12

**Dependencies:** U1, U2

**Files:**
- `base/entrypoint.sh`
- `base/setup.example.json`
- `base/.example.env`

**Approach:** Add a new step near the top of `entrypoint.sh` — before the `SETUP_INITIALIZED_MARKER` guard's `if` statement, not after it — that reads `setup.json`'s `.docker.enabled` field with the same `jq`-based pattern the other config-reading functions already use, defaulting to disabled when absent. When enabled: launch `supervisord` (whose own config then autostarts `dockerd-rootless.sh` per U2), handling a synchronous launch failure by logging and continuing rather than letting it propagate under `set -e`; then run an unconditional readiness wait for the daemon to come up or visibly fail, before the marker-guarded setup block runs. Because this whole step sits outside the marker guard, it runs on every container start (R8) and always completes before `docker_login()` — which lives inside the guarded block — ever polls, fixing the sequencing that would otherwise leave registry login permanently broken whenever Docker is enabled. When disabled (the default), skip this step entirely and change nothing else — `docker_login()` behaves exactly as it does in `dev-image:base` today. Point the Docker CLI's default context/`DOCKER_HOST` at the `dockerd` account's rootless socket only when enabled, so root-run commands reach it without `sudo`. Add the `docker` block to `base/setup.example.json` and document `docker.enabled` in `base/.example.env`.

**Test scenarios:**
- Happy path (enabled): on a fresh container start with `docker.enabled: true`, supervisor starts `dockerd-rootless.sh`, the readiness wait observes it, and `docker_login()` (when credentials are set) succeeds against the local daemon.
- Happy path (default/disabled): **Covers AE5.** On a fresh container start with `setup.json` absent or `docker.enabled` unset, supervisor is never launched, and behavior is identical to `dev-image:base` today.
- Restart path: **Covers AE1.** On a restart of an already-initialized, Docker-enabled container, supervisor still starts `dockerd` even though the rest of setup is skipped.
- No-credentials path: **Covers AE4.** On a Docker-enabled container started without `DOCKER_USERNAME`/`DOCKER_PASSWORD`, the readiness wait still runs before the setup block, so the daemon has had a chance to come up before anything else proceeds.
- Failure isolation: **Covers AE3.** If the supervisor-launch step itself fails synchronously (simulate with a broken `supervisord.conf`), `entrypoint.sh` logs the failure and still reaches `exec "$@"`.
- Regression check: all `SETUP_INITIALIZED_MARKER`-guarded functions still skip on restart exactly as before, regardless of the Docker opt-in state.

**Verification:** Exercise fresh starts with Docker enabled, disabled, and unset, plus a restart of an already-initialized enabled container; confirm `dockerd` is reachable only when enabled, the other setup functions only ran once, disabled containers show zero behavioral difference from `dev-image:base` today, and a deliberately broken supervisor config doesn't prevent the container's main process from starting.

---

### U4. Document the opt-in Docker option, the sidecar alternative, and rootless limitations

**Goal:** Document both paths to working Docker-in-Docker (the unchanged sidecar, and the new opt-in embedded daemon), the runtime grants the embedded option needs, and its known limitations and seccomp exposure.

**Requirements:** R13, R14

**Dependencies:** U3

**Files:**
- `README.md`

**Approach:** Add a section presenting the `docker:dind` sidecar (unchanged) and the embedded-daemon opt-in as two alternatives, with the trade-off between them stated plainly. For the embedded option, document the `setup.json` `docker.enabled` field, the required `docker run`/compose `/dev/fuse` device and seccomp relaxation, rootless mode's limitations (unenforced CPU/memory limits, slower userspace networking, no macvlan/GPU passthrough), and the fact that the seccomp relaxation applies to the whole container, not just the daemon.

**Test expectation:** none — documentation-only change.

## System-Wide Impact

- **Every existing consumer of `dev-image:base` gets a larger image** (the daemon, supervisor, and their dependencies are always installed), but **no behavioral change unless they explicitly opt in** via `setup.json`. `git_setup`, `claude_setup`, `copilot_setup`, `bitbucket_setup`, `gcloud_setup`, `aws_setup`, and `custom_scripts_setup` are unaffected either way; `examples/docker-compose.yml`'s `mongo`/`postgres` services and the untouched `docker:dind` sidecar are unaffected.
- **Consumers who opt in without granting the required `/dev/fuse` device and seccomp relaxation** get a daemon that logs a startup failure and keeps retrying in the background (AE2) rather than one that's silently absent — the launch step's failure isolation (R9) and the unconditional readiness wait (R10) mean the rest of the container still starts normally either way.
- **External consumers building `FROM cristianat/development:latest`** (none exist in this repo today, but the image is published to Docker Hub) get the size increase transparently on their next pull, but no behavior change unless they also update their own `setup.json` — a meaningfully smaller blast radius than an always-on default would have had, which is why this ships as a normal feature release rather than a breaking one.

## Risks & Dependencies

- **Image size regression.** This reverses some of the prior image-size-reduction work (`a7e407e`) for every consumer, including those who never enable Docker — the opt-in mitigates *behavior* change, not the size increase itself. Accepted trade-off of keeping a single image.
- **Host kernel dependency.** Whether the required seccomp relaxation is actually permitted depends on the outer container runtime and host kernel — outside this repo's control.
- **The no-`sudo` socket design assumes root retains `CAP_DAC_OVERRIDE`.** Hardened runtimes (Kubernetes restricted Pod Security Admission, `--cap-drop=ALL` CI runners) can strip this from root, which would make the daemon's socket unreachable from root — a distinct failure with the same symptom as AE2 (daemon unreachable) but a different cause and no dedicated diagnostic. Accepted as a known limitation of the single-account design; not mitigated in this plan.
- **Enabling Docker relaxes seccomp for the whole container, not just `dockerd`.** Every other tool in this image (terraform, gcloud, aws-cli, kubectl, the developer's own shell) loses syscall filtering for as long as the container runs, since `security_opt` is container-scoped. Opt-in limits this to consumers who explicitly choose it; a narrower custom seccomp profile is deferred (see Scope Boundaries).
- **Unbounded resource consumption by nested containers (host DoS exposure).** Containers built/run by the embedded rootless daemon aren't subject to enforced CPU/memory limits (rootless mode lacks real cgroup delegation without host-level setup this image doesn't attempt). A runaway nested container can consume unbounded host resources. Opt-in scope limits exposure to consumers who explicitly enable Docker.

## Scope Boundaries

**Deferred for later**
- A privileged/rootful daemon mode — would need to be a genuinely separate image or a second opt-in value, evaluated only if the rootless limitations above become blocking in practice.
- A seccomp profile scoped to just the syscalls rootless `dockerd` needs, narrower than `unconfined` — real effort to get right; `unconfined` ships now with the blast radius explicitly documented.

**Outside this scope**
- Making `claude_setup`/`copilot_setup`/`bitbucket_setup` idempotent — unrelated to this change; the marker continues to guard them exactly as it does today.

## Sources / Research

- `base/entrypoint.sh:3` (`set -euo pipefail`), `base/entrypoint.sh:291-294` (`docker_login()`'s credential-gated poll), and `base/entrypoint.sh:421-448` (the `SETUP_INITIALIZED_MARKER` guard structure) — together the basis for placing the opt-in check and supervisor-start step before the guarded setup block, fixing a sequencing defect found during document review where `docker_login()` (called inside the guard) would otherwise poll a daemon supervisor had not yet been asked to start.
- `base/Dockerfile:85-88` — existing Docker apt repo/keyring registration that the new packages extend.
- `.github/workflows/release.yml` — single hardcoded `docker/build-push-action@v6` step (`context: ./base`, tags `<version>` + `latest`); no changes needed there — this plan ships as a normal feature release, not a breaking one, since default behavior is unchanged for consumers who don't opt in.
- [Rootless mode | Docker Docs](https://docs.docker.com/engine/security/rootless/) — prerequisites (`uidmap`, subuid/subgid ≥65,536), socket path convention (`unix:///run/user/<uid>/docker.sock`), and confirmation that the setup tool refuses to run as root.
- [moby/contrib/dockerd-rootless-setuptool.sh](https://github.com/moby/moby/blob/master/contrib/dockerd-rootless-setuptool.sh) — non-systemd guidance to run `dockerd-rootless.sh` directly, and the environment variables (`XDG_RUNTIME_DIR`, `PATH`, `DOCKER_HOST`) it needs.
- [docker-library/docker dockerd-entrypoint.sh](https://github.com/docker-library/docker/blob/master/dockerd-entrypoint.sh) — prior art for supervising the rootless launch path directly rather than the setup tool.
- [packages.ubuntu.com/noble/supervisor](https://packages.ubuntu.com/noble/supervisor) — confirms `supervisor` is a clean, non-interactive apt install on Ubuntu 24.04.
