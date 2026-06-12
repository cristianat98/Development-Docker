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
- **AI agent tooling**: GitHub Copilot CLI, Claude CLI

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
**files directory**, which mirrors `base/entrypoint/` in this repo — drop your
own copies of those files there (`base/entrypoint/CLAUDE.example.md` shows the
expected shape for a global `CLAUDE.md`).

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
    gpg --export-secret-keys --armor <KEYID> > ./base/entrypoint/id_signing.asc
    ```
    Drop the exported file into `base/entrypoint/` — `gpg_key` resolves against
    the files directory the same way as `claude.global_md`. `signing_key_id` is
    the long key ID/fingerprint from `gpg --list-secret-keys --keyid-format=long`.
  - `ssh_keys` — array of `{ ssh_file, host }`. Generate a key pair with:
    ```bash
    ssh-keygen -t ed25519 -C "you@example.com" -f ./base/entrypoint/id_ed25519_github
    ```
    then drop the **private** key into `base/entrypoint/` (`.gitignore` already
    excludes `id_ed25519*`/`id_rsa*`/`id_ecdsa*` there). `ssh_file` resolves
    against the files directory; `host` is written as a `Host` block in
    `~/.ssh/config`.

- **`scripts.dir`** — resolved against the files directory. Every `*.sh` file
  directly inside it runs at container start, in sorted filename order
  (prefix with `00-`, `01-`, … to control ordering). Executable files run
  directly; non-executable files run via `bash`. Runs before the Claude/Copilot
  setup below, so a script here can install CLIs (e.g. `rtk`,
  `notebooklm-mcp-cli`) that those steps detect and configure automatically.

- **`claude`** / **`copilot`** — same shape for both agents:
  - `global_md` — global instructions file, resolved against the files
    directory and installed as `~/.claude/CLAUDE.md` (Claude only;
    `base/entrypoint/CLAUDE.example.md` shows the expected shape)
  - `skills_dir` — resolved against the files directory; every immediate
    subdirectory is installed as a skill, e.g.
    `claude-skills/3gpp-expert/SKILL.md` → `~/.claude/skills/3gpp-expert/SKILL.md`
    (or `~/.copilot/skills/...` for Copilot)
  - `http_mcps` — array of `{ name, url }` HTTP MCP servers
  - `stdio_mcps` — array of `{ name, command }`, where `command` is the full
    shell command string, split at runtime
  - `plugins` — array of `{ marketplace_id, plugin_id }`; Copilot installs
    using the compound `plugin_id@marketplace_id` form

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

## What the entrypoint does

On every start, `entrypoint.sh` runs through the following steps, each skipped
gracefully when its prerequisites (env vars, `setup.json` keys, installed CLIs)
are missing, before finally `exec`ing the container's `CMD`:

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
6. **Bitbucket CLI** — creates the default profile from `BITBUCKET_USER`/`BITBUCKET_PASSWORD`
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
```
