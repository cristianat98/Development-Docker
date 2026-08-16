# Development-Docker

A pre-configured, customizable Ubuntu 24.04 development image. It bundles common
languages, cloud/infra CLIs and AI agent tooling, then uses an entrypoint script
to bootstrap your personal Git identity, credentials and agent configuration on
container start — so you can `docker exec` straight into a ready-to-work shell.

## What's included

- **Core tools**: curl, wget, git, jq, htop, nmap, tcpdump, openssh-client, sudo, etc.
- **Languages/runtimes**: Python 3 + Python 3.14, Node.js LTS (via nvm), Go 1.21.5, OpenJDK 21
- **Cloud & infrastructure CLIs**: Docker CLI, Terraform + tflint, Google Cloud SDK, AWS CLI, kubectl, Ansible
- **VCS & collaboration**: Git (latest via PPA), GitHub CLI (`gh`), Bitbucket CLI (`bb`), pre-commit + go-pre-commit
- **Databases**: MongoDB Shell (`mongosh`), PostgreSQL client (`psql`)
- **CI & code quality**: `act` (run GitHub Actions locally), SonarQube Scanner CLI
- **AI agent tooling**: GitHub Copilot CLI, Claude CLI, opencode

## Build

```bash
docker build -t dev-image:base ./base
```

## Releases

Versioning is automated by [semantic-release](https://semantic-release.gitbook.io/)
based on [Conventional Commits](https://www.conventionalcommits.org/) — write
commit messages on `master` as `feat: ...`, `fix: ...`, `feat!: ...` /
`BREAKING CHANGE: ...`, etc., and the next semver bump (major/minor/patch) is
inferred automatically; commits that don't match any recognized type don't
trigger a release.

On every push to `master`, `.github/workflows/release.yml`:
1. Runs semantic-release, which tags the commit, publishes a GitHub release
   with generated notes, and decides whether a new version is warranted
2. If a new version was published, builds `base/Dockerfile` and pushes
   `cristianat/development:<version>` and `cristianat/development:latest` to
   Docker Hub

Requires the `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` repository secrets
(a Docker Hub access token, not your account password).

## Configure

Container setup is driven by two files that you copy from the tracked `*.example.*`
templates and fill in (both are gitignored so your secrets stay local):

| Template | Copy to | Purpose |
| --- | --- | --- |
| `base/.example.env` | `.env` | Secrets and tokens passed as environment variables (GitHub, Context7, Bitbucket, Docker registry, GCloud, AWS, plus the paths described below) |
| `base/setup.example.json` | `setup.json` | Git identity/signing/SSH keys, Claude/Copilot integrations (skills, MCP servers, plugins), custom startup scripts |

`setup.json` references additional files (SSH/GPG keys, a global `CLAUDE.md`,
skill directories, custom scripts) by path. These are resolved relative to the
**files directory**, which is `examples/entrypoint/` in this repo — drop your
own copies of those files there (`examples/entrypoint/CLAUDE.example.md` shows
the expected shape for a global `CLAUDE.md`).

### `setup.json` field reference

`setup.example.json` is the tracked, comment-free template — copy it to
`setup.json` (gitignored) and fill in only the sections you need; omitted
sections, empty arrays and absent keys are silently skipped.

- **`git`** — all fields optional.
  - `name` / `email` → `git config --global user.name`/`user.email`
  - `gpg_key` / `signing_key_id` — configure commit signing. Requires a
    **passphrase-less** signing key, since the entrypoint runs
    `gpg --batch --import` non-interactively:
    ```bash
    gpg --batch --passphrase '' --quick-generate-key "Your Name <you@example.com>" ed25519 sign 0
    gpg --export-secret-keys --armor <KEYID> > ./examples/entrypoint/id_signing.asc
    ```
    Drop the exported file into `examples/entrypoint/` — `gpg_key` resolves against
    the files directory the same way as `claude.global_md`. `signing_key_id` is
    the long key ID/fingerprint from `gpg --list-secret-keys --keyid-format=long`.
  - `ssh_keys` — array of `{ ssh_file, host }`. Generate a key pair with:
    ```bash
    ssh-keygen -t ed25519 -C "you@example.com" -f ./examples/entrypoint/id_ed25519_github
    ```
    then drop the **private** key into `examples/entrypoint/` (`.gitignore` already
    excludes `id_ed25519*`/`id_rsa*`/`id_ecdsa*` there). `ssh_file` resolves
    against the files directory; `host` is written as a `Host` block in
    `~/.ssh/config`.

- **`scripts.dir`** — resolved against the files directory. Every `*.sh` file
  directly inside it runs at container start, in sorted filename order
  (prefix with `00-`, `01-`, … to control ordering). Executable files run
  directly; non-executable files run via `bash`. Runs before the Claude/Copilot
  setup below, so a script here can install CLIs (e.g. `rtk`,
  `notebooklm-mcp-cli`) that those steps detect and configure automatically.

- **`docker.enabled`** — opt-in flag for the embedded rootless Docker daemon.
  Defaults to `false` (or is skipped entirely if `setup.json` is absent),
  which preserves today's behavior exactly. See "Docker-in-Docker: sidecar
  vs. embedded daemon" under Run below for what enabling it requires and how
  it compares to the `docker:dind` sidecar.

- **`claude`** / **`copilot`** — same shape for both agents:
  - `global_md` — global instructions file, resolved against the files
    directory and installed as `~/.claude/CLAUDE.md` (Claude only;
    `examples/entrypoint/CLAUDE.example.md` shows the expected shape)
  - `skills_dir` — resolved against the files directory; every immediate
    subdirectory is installed as a skill, e.g.
    `claude-skills/3gpp-expert/SKILL.md` → `~/.claude/skills/3gpp-expert/SKILL.md`
    (or `~/.copilot/skills/...` for Copilot)
  - `http_mcps` — array of `{ name, url }` HTTP MCP servers
  - `stdio_mcps` — array of `{ name, command }`, where `command` is the full
    shell command string, split at runtime
  - `plugins` — array of `{ marketplace_id, plugin_id }`; Copilot installs
    using the compound `plugin_id@marketplace_id` form

- **`opencode`** — same `global_md`/`skills_dir`/`http_mcps`/`stdio_mcps`
  shape as `claude`/`copilot` above (global instructions installed as
  `~/.config/opencode/AGENTS.md`, skills under
  `~/.config/opencode/skills/...`), written non-interactively straight into
  `~/.config/opencode/opencode.json`'s `mcp` key:
  - `global_md` — resolved against the files directory and installed as
    `~/.config/opencode/AGENTS.md`
    (`examples/entrypoint/AGENTS.example.md` shows the expected shape)
  - `skills_dir` — resolved against the files directory; every immediate
    subdirectory is installed as a skill under `~/.config/opencode/skills/...`
  - `http_mcps` — array of `{ name, url }` HTTP MCP servers
  - `stdio_mcps` — array of `{ name, command }`, where `command` is the full
    shell command string, split at runtime
  - `plugins` — flat array of npm package name strings (unlike `claude`'s
    `{ marketplace_id, plugin_id }` objects — `opencode` has no plugin
    marketplace to mirror), merged into `opencode.json`'s `plugin` array

By default the entrypoint looks for the config at `/entrypoint/setup.json` and
the files directory at `/entrypoint/files`; override these with the
`SETUP_CONFIG` / `SETUP_FILES_DIR` environment variables if you mount them
elsewhere.

## Run

### With Docker Compose (recommended)

`examples/docker-compose.yml` is a ready-to-run setup for the `dev-image:base`
image you built above: it mounts `setup.json` and the `entrypoint/` files
directory at the expected paths, loads `.env`, and starts a `docker:dind`
sidecar (`docker-daemon`) plus MongoDB and PostgreSQL instances — so the
bundled `docker`, `mongosh` and `psql` clients all have something to talk to
without touching the host. No host Docker socket required: set
`DOCKER_HOST=tcp://docker-daemon:2375` in your `.env` so the container's
Docker CLI talks to the sidecar (reach the databases as `mongo:27017` /
`postgres:5432`):

```bash
cd examples
docker compose up -d
docker compose exec dev bash
```

Drop the `docker-daemon` service (and the `DOCKER_HOST` variable) from your
`.env` if you'd rather mount the host's Docker socket instead.

### With plain `docker run`

```bash
docker run -it --rm \
  --env-file .env \
  -v "$(pwd)/setup.json:/entrypoint/setup.json" \
  -v "$(pwd)/entrypoint:/entrypoint/files" \
  dev-image:base \
  bash
```

The default `CMD` is `sleep infinity`, so a container started without overriding
the command stays alive for you to `docker exec -it <container> bash` into.

### Docker-in-Docker: sidecar vs. embedded daemon

There are two ways to give the bundled Docker CLI a daemon to talk to. Pick
based on your own trade-off tolerance:

- **`docker:dind` sidecar** (`examples/docker-compose.yml`'s `docker-daemon`
  service, described above) — simplest to set up, but it's a separate
  container with its own filesystem. Bind-mount source paths passed to
  `docker run -v $(pwd)/...` must exist identically on both containers, or
  the mount resolves to an empty or wrong directory on the sidecar's side.
- **Embedded rootless daemon** (opt-in, new in this image) — the daemon runs
  inside the dev container itself, so client and daemon share one
  filesystem and bind-mount paths always resolve correctly. In exchange, it
  must be explicitly enabled in `setup.json` and the container needs extra
  runtime permissions, described below.

#### Enabling the embedded daemon

Set `docker.enabled: true` in `setup.json`:

```json
"docker": {
  "enabled": true
}
```

When enabled, `entrypoint.sh` starts `supervisord`, which launches
`dockerd-rootless.sh` as a dedicated `dockerd` account, waits for the daemon
to become reachable, and points the Docker CLI at it via a Docker context
(`embedded-rootless`, targeting `unix:///run/user/<uid>/docker.sock`). A
context is used rather than an environment variable so that `docker exec`
sessions — which start from the container's own environment, not the
entrypoint's — also resolve the daemon. This step runs on every container
start, including restarts of an already initialized container.

**`DOCKER_HOST` wins over `docker.enabled`.** If `DOCKER_HOST` is set, the
entrypoint uses that daemon and skips the embedded one entirely, logging
which it chose. That keeps the sidecar workflow working unchanged — set
`DOCKER_HOST=tcp://docker-daemon:2375` and you get the sidecar whatever
`docker.enabled` says. The precedence runs this way because `docker exec`
sessions inherit `DOCKER_HOST` from the container environment, where it
overrides any context the entrypoint sets; deferring to it keeps every shell
in the container pointed at the same daemon. To use the embedded daemon,
leave `DOCKER_HOST` unset.

The container also needs two extra runtime grants for the rootless daemon
to actually start: the `/dev/fuse` device (needed by the
`fuse-overlayfs` storage driver) and a seccomp relaxation (rootless
`dockerd` needs syscalls a default seccomp profile blocks).

**With Docker Compose:**

```yaml
services:
  dev:
    image: dev-image:base
    devices:
      - /dev/fuse
    security_opt:
      - seccomp=unconfined
    # ...env_file, volumes, etc. as in examples/docker-compose.yml
```

**With plain `docker run`:**

```bash
docker run -it --rm \
  --device /dev/fuse \
  --security-opt seccomp=unconfined \
  --env-file .env \
  -v "$(pwd)/setup.json:/entrypoint/setup.json" \
  -v "$(pwd)/entrypoint:/entrypoint/files" \
  dev-image:base \
  bash
```

Without both grants, `dockerd` fails to start; supervisor logs the failure
clearly instead of silently crash-looping, and the rest of the container
keeps working normally — you just won't have a usable Docker daemon.

**Whole-container seccomp exposure.** `security_opt` applies to the entire
container, not to a single process. Setting `seccomp=unconfined` to let
rootless `dockerd` start relaxes syscall filtering for everything else
running in the container too — terraform, gcloud, aws-cli, kubectl, and your
own shell — not just the daemon, for as long as the container runs. This is
the trade-off enabling Docker makes; a narrower, Docker-only seccomp profile
is possible in principle but isn't shipped today.

#### Rootless mode limitations

Independent of this image, Docker's rootless mode has known limitations
worth knowing before you rely on the embedded daemon:

- **CPU/memory limits aren't enforced.** Rootless mode lacks real cgroup
  delegation without additional host-level setup this image doesn't
  attempt, so containers built/run against the embedded daemon aren't
  actually constrained by any limits you set — a runaway nested container
  can consume unbounded host resources.
- **Networking is slower.** Rootless Docker routes traffic through a
  userspace networking stack instead of the kernel-level networking a
  rootful daemon uses, adding overhead.
- **No macvlan networks or GPU passthrough.** Both require privileges
  rootless mode doesn't have.

## What the entrypoint does

Before any of the steps below, and on *every* start (even restarts of an
already-initialized container), `entrypoint.sh` checks `setup.json`'s
`docker.enabled` field and, if `true`, starts the embedded rootless Docker
daemon and waits for it to become reachable — see "Docker-in-Docker: sidecar
vs. embedded daemon" above. This runs first so the daemon is already up by
the time step 7 below tries to log in to it.

On every start, `entrypoint.sh` then runs through the following steps, each
skipped gracefully when its prerequisites (env vars, `setup.json` keys,
installed CLIs) are missing, before finally `exec`ing the container's `CMD`:

1. **GitHub CLI login** — authenticates `gh` using `GITHUB_TOKEN`
2. **Git setup** — sets `user.name`/`user.email`, imports a passphrase-less GPG
   signing key and configures commit signing, and installs SSH keys/host blocks
   from `setup.json`
3. **Custom scripts** — runs every `*.sh` file in the directory pointed to by
   `scripts.dir` in `setup.json`, in sorted filename order. Runs before the
   Claude/Copilot setup below, so a script here can install CLIs (e.g. RTK,
   NotebookLM CLI) that those steps detect and configure
4. **Claude CLI setup** — installs the global `CLAUDE.md`, skill directories,
   HTTP/stdio MCP servers and plugins from `setup.json`; also initialises RTK
   (if `rtk` is on `PATH`), configures NotebookLM (if its CLI is installed)
   and registers the Context7 MCP server (if `CONTEXT7_API_KEY` is set)
5. **Copilot CLI setup** — same categories as Claude, adapted for `copilot`
6. **Bitbucket CLI** — writes `~/.bitbucket-rest-cli-config.json` (`auth.username`/`auth.appPassword`) from `BITBUCKET_USER`/`BITBUCKET_PASSWORD`
7. **Docker registry login** — waits for the Docker daemon, then logs in with
   `DOCKER_USERNAME`/`DOCKER_PASSWORD` (optionally against `DOCKER_REGISTRY`)
8. **Google Cloud setup** — decodes `GCLOUD_SERVICE_ACCOUNT_KEY_B64`, activates
   the service account and optionally selects `GCLOUD_PROJECT_ID`
9. **AWS CLI setup** — configures a named profile from `AWS_ACCESS_KEY_ID` /
   `AWS_SECRET_ACCESS_KEY` (and optional session token / region)

## Manual post-setup

A few integrations require an interactive login and aren't automated:

- NotebookLM CLI: `nlm login`
- Notion / Atlassian / Microsoft MCP logins
- Resolve the Context7 setup issue (the entrypoint configures the MCP server,
  but `npx ctx7 setup` itself can't run non-interactively)
- Add your SSH/GPG keys to your Git host if you haven't already
- GitHub Copilot CLI: `copilot auth login`
- Claude CLI: `claude auth login`

## Verifying the image

Once inside the container, confirm the toolchain is in place:

```bash
python3 --version && pip3 --version && python3.14 --version
node --version && npm --version
go version
java -version && javac -version
git --version
pre-commit --version && go-pre-commit --version
docker --version
terraform version && tflint --version
gcloud --version
aws --version
ansible --version && ansible-lint --version
kubectl version
mongosh --version
psql --version
act --version
gh --version
bb --version
sonar-scanner --version
copilot --version
claude --version
opencode --version
```
