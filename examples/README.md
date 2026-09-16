# Examples

Two ready-to-run Compose setups for `dev-image:base`. Both start the same dev
container with MongoDB and PostgreSQL alongside it; they differ only in where
the Docker daemon lives.

| | [`dind/`](dind/) | [`embedded/`](embedded/) |
|---|---|---|
| Daemon runs in | a separate `docker:dind` sidecar | the dev container itself |
| Bind mounts from the dev container | source paths must exist on the sidecar too | always resolve — one filesystem |
| Extra container permissions | none on `dev` (sidecar is `privileged`) | `dev` itself must be `privileged` |
| Resource limits on nested containers | enforced | not supported (nested cgroups) |
| Enabled by | `DOCKER_HOST` in `.env` | `docker.enabled` in `setup.json` |

**Pick `dind/`** unless you need bind mounts to work from inside the dev
container. The sidecar is the simpler setup and keeps the dev container
unprivileged.

`embedded/` is single-instance by design: `/var/lib/docker` belongs to exactly
one daemon, so don't `--scale` the `dev` service or point a second container
at the same volume.

**Pick `embedded/`** when you run `docker run -v $(pwd):/app ...` from inside
the dev container. With the sidecar those paths exist on the dev container's
filesystem but not the sidecar's, so the mount silently resolves to an empty
or wrong directory; sharing one filesystem fixes that structurally.

`DOCKER_HOST` takes precedence over `docker.enabled` — if it is set, the
entrypoint uses that daemon and skips the embedded one, logging which it
chose. That is why `embedded/.env` deliberately leaves it unset.

## Running either one

```bash
cd dind        # or: cd embedded
docker compose up -d
docker compose exec dev bash
```

Both directories ship a working `.env` and `setup.json` you can edit in
place. `../base/.example.env` documents every environment variable the
entrypoint reads, and the root `README.md` documents every `setup.json` field.

## Shared files

`entrypoint/` is shared by both examples — each compose file mounts it at
`/entrypoint/files`, and `setup.json` paths resolve against it:

- `CLAUDE.example.md` / `AGENTS.example.md` — global instruction files for
  Claude Code and opencode
- `scripts/` — custom setup scripts run at the end of container init

Drop your own SSH keys and GPG keys here too when `setup.json` references
them; the root `.gitignore` already excludes the usual key filenames.
