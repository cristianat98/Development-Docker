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
- **AI agent tooling**: GitHub Copilot CLI, Claude CLI, NotebookLM CLI, Context7 CLI, RTK

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
| `.example.env` | `.env` | Secrets and tokens passed as environment variables (GitHub, Context7, Bitbucket, Docker registry, GCloud, AWS, plus the paths described below) |
| `setup.example.json` | `setup.json` | Git identity/signing/SSH keys, Claude/Copilot integrations (skills, MCP servers, plugins, RTK, Context7, NotebookLM), custom startup scripts |

`setup.json` references additional files (SSH/GPG keys, a global `CLAUDE.md`,
skill directories, custom scripts) by path. These are resolved relative to the
**files directory**, which mirrors `entrypoint/` in this repo — drop your own
copies of those files there (`entrypoint/CLAUDE.example.md` shows the expected
shape for a global `CLAUDE.md`).

By default the entrypoint looks for the config at `/entrypoint/setup.json` and
the files directory at `/entrypoint/files`; override these with the
`SETUP_CONFIG` / `SETUP_FILES_DIR` environment variables if you mount them
elsewhere.

## Run

### With Docker Compose (recommended)

`examples/docker-compose.yml` is a ready-to-run setup: it pulls the published
`cristianat/development:latest` image, mounts `setup.json` and the
`entrypoint/` files directory at the expected paths, loads `.env`, and starts
a `docker:dind` sidecar (`docker-daemon`) — no host Docker socket required.
Set `DOCKER_HOST=tcp://docker-daemon:2375` in your `.env` so the container's
Docker CLI talks to that sidecar:

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
3. **Claude CLI setup** — installs the global `CLAUDE.md`, skill directories,
   RTK, NotebookLM, HTTP/stdio MCP servers, plugins and Context7 (when
   `CONTEXT7_API_KEY` is set)
4. **Copilot CLI setup** — same categories as Claude, adapted for `copilot`
5. **Bitbucket CLI** — creates the default profile from `BITBUCKET_USER`/`BITBUCKET_PASSWORD`
6. **Docker registry login** — waits for the Docker daemon, then logs in with
   `DOCKER_USERNAME`/`DOCKER_PASSWORD` (optionally against `DOCKER_REGISTRY`)
7. **Google Cloud setup** — decodes `GCLOUD_SERVICE_ACCOUNT_KEY_B64`, activates
   the service account and optionally selects `GCLOUD_PROJECT_ID`
8. **AWS CLI setup** — configures a named profile from `AWS_ACCESS_KEY_ID` /
   `AWS_SECRET_ACCESS_KEY` (and optional session token / region)
9. **Custom scripts** — runs every `*.sh` file in the directory pointed to by
   `scripts.dir` in `setup.json`, in sorted filename order

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
