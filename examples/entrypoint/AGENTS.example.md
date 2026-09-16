# Development container

You are running inside the `dev-image:base` container. The following CLIs are
pre-installed — prefer them over ad-hoc scripts or raw API calls:

- `gh` (GitHub CLI) and `bb` (Bitbucket CLI) for VCS, issue and PR operations
- `docker`, `terraform` + `tflint`, `kubectl`, `ansible` for infrastructure
- `aws` and `gcloud` for cloud operations (credentials come from `.env` via
  the entrypoint)
- `mongosh` and `psql` for database access
- `act` to run GitHub Actions workflows locally
- `sonar-scanner` for code quality scans

## Conventions

- Follow Conventional Commits for commit messages (`feat:`, `fix:`, `chore:`, etc.).
- Run the project's own lint/test commands before considering a change done.
