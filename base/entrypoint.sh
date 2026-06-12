#!/usr/bin/env bash

set -euo pipefail

log() {
    echo "[entrypoint] $*"
}

github_login() {
    local token="${GITHUB_TOKEN:-}"

    if [[ -z "$token" ]]; then
        log "Skipping GitHub authentication because GITHUB_TOKEN is not set."
        return
    fi

    export GITHUB_TOKEN="$token"

    if gh auth status --hostname github.com >/dev/null 2>&1; then
        log "GitHub CLI is already authenticated for github.com."
    else
        log "Authenticating GitHub CLI for github.com..."
        printf '%s' "$token" | gh auth login --hostname github.com --with-token
    fi

    log "GitHub CLI authentication ready for github.com."
}

git_setup() {
    local config_file="${SETUP_CONFIG:-/entrypoint/setup.json}"
    local files_dir="${SETUP_FILES_DIR:-/entrypoint/files}"

    if [[ ! -f "$config_file" ]]; then
        log "Skipping Git setup because $config_file is not present."
        return
    fi

    local name email
    name=$(jq -r '.git.name // empty' "$config_file")
    email=$(jq -r '.git.email // empty' "$config_file")

    if [[ -n "$name" ]]; then
        git config --global user.name "$name"
        log "Git user.name set to $name."
    fi

    if [[ -n "$email" ]]; then
        git config --global user.email "$email"
        log "Git user.email set to $email."
    fi

    # gpg signing key (passphrase-less key expected — see setup.example.json)
    local gpg_key signing_key_id
    gpg_key=$(jq -r '.git.gpg_key // empty' "$config_file")
    signing_key_id=$(jq -r '.git.signing_key_id // empty' "$config_file")

    if [[ -n "$gpg_key" && -n "$signing_key_id" ]]; then
        local gpg_src="${files_dir}/${gpg_key}"
        if [[ -f "$gpg_src" ]]; then
            gpg --batch --import "$gpg_src"
            git config --global user.signingkey "$signing_key_id"
            git config --global commit.gpgsign true
            log "Git commit signing configured with key $signing_key_id from $gpg_src."
        else
            log "Skipping GPG signing key: $gpg_src not found."
        fi
    elif [[ -n "$gpg_key" || -n "$signing_key_id" ]]; then
        log "Skipping GPG signing key: both git.gpg_key and git.signing_key_id are required."
    fi

    # ssh keys
    local count
    count=$(jq '.git.ssh_keys // [] | length' "$config_file")
    if [[ "$count" -gt 0 ]]; then
        mkdir -p /root/.ssh
        chmod 700 /root/.ssh

        local ssh_config="/root/.ssh/config"
        touch "$ssh_config"
        chmod 600 "$ssh_config"

        for i in $(seq 0 $((count - 1))); do
            local ssh_file host src dest
            ssh_file=$(jq -r ".git.ssh_keys[$i].ssh_file" "$config_file")
            host=$(jq -r ".git.ssh_keys[$i].host" "$config_file")
            src="${files_dir}/${ssh_file}"
            dest="/root/.ssh/${ssh_file}"

            if [[ ! -f "$src" ]]; then
                log "Skipping SSH key for $host: $src not found."
                continue
            fi

            cp "$src" "$dest"
            chmod 600 "$dest"
            log "SSH key for $host installed from $src."

            if grep -q "^Host $host\$" "$ssh_config"; then
                log "SSH config for $host already present, skipping."
            else
                cat >>"$ssh_config" <<EOF
Host $host
    HostName $host
    User git
    IdentityFile $dest
    IdentitiesOnly yes
EOF
                log "SSH config for $host written."
            fi
        done
    fi
}

install_skills() {
    local agent="$1"
    local src="$2"
    local target_dir="$3"

    if [[ ! -d "$src" ]]; then
        log "Skipping $agent skills: $src not found."
        return
    fi

    mkdir -p "$target_dir"

    local skill name
    for skill in "$src"/*/; do
        [[ -d "$skill" ]] || continue
        name=$(basename "$skill")
        rm -rf "${target_dir:?}/${name}"
        cp -r "$skill" "${target_dir}/${name}"
        log "Installed $agent skill: $name"
    done
}

claude_setup() {
    local config_file="${SETUP_CONFIG:-/entrypoint/setup.json}"
    local files_dir="${SETUP_FILES_DIR:-/entrypoint/files}"

    if [[ ! -f "$config_file" ]]; then
        log "Skipping Claude setup because $config_file is not present."
        return
    fi

    if ! command -v claude >/dev/null 2>&1; then
        log "Skipping Claude setup because claude is not installed."
        return
    fi

    # global CLAUDE.md
    local global_md
    global_md=$(jq -r '.claude.global_md // empty' "$config_file")
    if [[ -n "$global_md" ]]; then
        local src="${files_dir}/${global_md}"
        if [[ -f "$src" ]]; then
            mkdir -p /root/.claude
            cp "$src" /root/.claude/CLAUDE.md
            log "Claude CLAUDE.md installed from $src."
        else
            log "Skipping Claude global MD: $src not found."
        fi
    fi

    # skills
    local skills_dir
    skills_dir=$(jq -r '.claude.skills_dir // empty' "$config_file")
    if [[ -n "$skills_dir" ]]; then
        install_skills "Claude" "${files_dir}/${skills_dir}" /root/.claude/skills
    fi

    # http mcps
    local count
    count=$(jq '.claude.http_mcps // [] | length' "$config_file")
    for i in $(seq 0 $((count - 1))); do
        local name url
        name=$(jq -r ".claude.http_mcps[$i].name" "$config_file")
        url=$(jq -r ".claude.http_mcps[$i].url" "$config_file")
        log "Adding Claude HTTP MCP: $name -> $url"
        claude mcp add --scope user --transport http "$name" "$url"
    done

    # stdio mcps
    count=$(jq '.claude.stdio_mcps // [] | length' "$config_file")
    for i in $(seq 0 $((count - 1))); do
        local name command
        local -a command_args
        name=$(jq -r ".claude.stdio_mcps[$i].name" "$config_file")
        command=$(jq -r ".claude.stdio_mcps[$i].command" "$config_file")
        read -ra command_args <<<"$command"
        log "Adding Claude stdio MCP: $name"
        claude mcp add --scope user --transport stdio "$name" -- "${command_args[@]}"
    done

    # plugins
    count=$(jq '.claude.plugins // [] | length' "$config_file")
    for i in $(seq 0 $((count - 1))); do
        local marketplace_id plugin_id
        marketplace_id=$(jq -r ".claude.plugins[$i].marketplace_id" "$config_file")
        plugin_id=$(jq -r ".claude.plugins[$i].plugin_id" "$config_file")
        log "Installing Claude plugin: $plugin_id from $marketplace_id"
        claude plugin marketplace add --scope user "$marketplace_id"
        claude plugin install --scope user "$plugin_id"
    done

    log "Claude setup completed."
}

copilot_setup() {
    local config_file="${SETUP_CONFIG:-/entrypoint/setup.json}"
    local files_dir="${SETUP_FILES_DIR:-/entrypoint/files}"

    if [[ ! -f "$config_file" ]]; then
        log "Skipping Copilot setup because $config_file is not present."
        return
    fi

    if ! command -v copilot >/dev/null 2>&1; then
        log "Skipping Copilot setup because copilot is not installed."
        return
    fi

    # skills
    local skills_dir
    skills_dir=$(jq -r '.copilot.skills_dir // empty' "$config_file")
    if [[ -n "$skills_dir" ]]; then
        install_skills "Copilot" "${files_dir}/${skills_dir}" /root/.copilot/skills
    fi

    # http mcps
    local count
    count=$(jq '.copilot.http_mcps // [] | length' "$config_file")
    for i in $(seq 0 $((count - 1))); do
        local name url
        name=$(jq -r ".copilot.http_mcps[$i].name" "$config_file")
        url=$(jq -r ".copilot.http_mcps[$i].url" "$config_file")
        log "Adding Copilot HTTP MCP: $name -> $url"
        copilot mcp add --transport http "$name" "$url"
    done

    # stdio mcps
    count=$(jq '.copilot.stdio_mcps // [] | length' "$config_file")
    for i in $(seq 0 $((count - 1))); do
        local name command
        local -a command_args
        name=$(jq -r ".copilot.stdio_mcps[$i].name" "$config_file")
        command=$(jq -r ".copilot.stdio_mcps[$i].command" "$config_file")
        read -ra command_args <<<"$command"
        log "Adding Copilot stdio MCP: $name"
        copilot mcp add --transport stdio "$name" -- "${command_args[@]}"
    done

    # plugins
    count=$(jq '.copilot.plugins // [] | length' "$config_file")
    for i in $(seq 0 $((count - 1))); do
        local marketplace_id plugin_id
        marketplace_id=$(jq -r ".copilot.plugins[$i].marketplace_id" "$config_file")
        plugin_id=$(jq -r ".copilot.plugins[$i].plugin_id" "$config_file")
        log "Installing Copilot plugin: $plugin_id from $marketplace_id"
        copilot plugin marketplace add "$marketplace_id"
        copilot plugin install "${plugin_id}@${marketplace_id}"
    done

    log "Copilot setup completed."
}


bitbucket_setup() {
    local user="${BITBUCKET_USER:-}"
    local password="${BITBUCKET_PASSWORD:-}"

    if [[ -z "$user" || -z "$password" ]]; then
        log "Skipping Bitbucket setup because BITBUCKET_USER or BITBUCKET_PASSWORD is not set."
        return
    fi

    if command -v bb >/dev/null 2>&1; then
        log "Configuring Bitbucket CLI profile..."
        bb profile create --name default --user "$user" --password "$password" --default
        log "Bitbucket CLI setup completed."
    fi
}

docker_login() {
    local user="${DOCKER_USERNAME:-}"
    local password="${DOCKER_PASSWORD:-}"
    local registry="${DOCKER_REGISTRY:-}"

    if [[ -z "$user" || -z "$password" ]]; then
        log "Skipping Docker registry login because DOCKER_USERNAME or DOCKER_PASSWORD is not set."
        return
    fi

    if ! command -v docker >/dev/null 2>&1; then
        log "Skipping Docker registry login because docker is not installed."
        return
    fi

    log "Waiting for the Docker daemon to be reachable..."
    local attempt
    for attempt in $(seq 1 30); do
        if docker info >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    if ! docker info >/dev/null 2>&1; then
        log "Skipping Docker registry login: Docker daemon is not reachable."
        return
    fi

    log "Logging in to Docker registry${registry:+ $registry}..."
    if [[ -n "$registry" ]]; then
        printf '%s' "$password" | docker login --username "$user" --password-stdin "$registry"
    else
        printf '%s' "$password" | docker login --username "$user" --password-stdin
    fi
    log "Docker registry login completed."
}

gcloud_setup() {
    local key_b64="${GCLOUD_SERVICE_ACCOUNT_KEY_B64:-}"
    local project_id="${GCLOUD_PROJECT_ID:-}"
    local key_file="/tmp/gcloud-service-account.json"

    if [[ -z "$key_b64" ]]; then
        log "Skipping Google Cloud setup because GCLOUD_SERVICE_ACCOUNT_KEY_B64 is not set."
        return
    fi

    if ! command -v gcloud >/dev/null 2>&1; then
        log "Skipping Google Cloud setup because gcloud is not installed."
        return
    fi

    log "Configuring Google Cloud service account credentials..."
    printf '%s' "$key_b64" | base64 -d > "$key_file"
    chmod 600 "$key_file"
    export GOOGLE_APPLICATION_CREDENTIALS="$key_file"

    gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"

    if [[ -n "$project_id" ]]; then
        gcloud config set project "$project_id"
    fi

    log "Google Cloud setup completed."
}

aws_setup() {
    local access_key_id="${AWS_ACCESS_KEY_ID:-}"
    local secret_access_key="${AWS_SECRET_ACCESS_KEY:-}"
    local session_token="${AWS_SESSION_TOKEN:-}"
    local region="${AWS_DEFAULT_REGION:-${AWS_REGION:-}}"
    local profile="${AWS_PROFILE:-default}"

    if [[ -z "$access_key_id" || -z "$secret_access_key" ]]; then
        log "Skipping AWS setup because AWS_ACCESS_KEY_ID or AWS_SECRET_ACCESS_KEY is not set."
        return
    fi

    if ! command -v aws >/dev/null 2>&1; then
        log "Skipping AWS setup because aws is not installed."
        return
    fi

    log "Configuring AWS CLI credentials..."
    mkdir -p /root/.aws

    aws configure set aws_access_key_id "$access_key_id" --profile "$profile"
    aws configure set aws_secret_access_key "$secret_access_key" --profile "$profile"

    if [[ -n "$session_token" ]]; then
        aws configure set aws_session_token "$session_token" --profile "$profile"
    fi

    if [[ -n "$region" ]]; then
        aws configure set region "$region" --profile "$profile"
    fi

    export AWS_PROFILE="$profile"

    log "AWS CLI setup completed."
}

custom_scripts_setup() {
    local config_file="${SETUP_CONFIG:-/entrypoint/setup.json}"
    local files_dir="${SETUP_FILES_DIR:-/entrypoint/files}"

    if [[ ! -f "$config_file" ]]; then
        log "Skipping custom scripts because $config_file is not present."
        return
    fi

    local scripts_dir
    scripts_dir=$(jq -r '.scripts.dir // empty' "$config_file")
    if [[ -z "$scripts_dir" ]]; then
        return
    fi

    local dir="${files_dir}/${scripts_dir}"
    if [[ ! -d "$dir" ]]; then
        log "Skipping custom scripts: $dir not found."
        return
    fi

    local script
    while IFS= read -r -d '' script; do
        log "Running custom script: $script"
        if [[ -x "$script" ]]; then
            "$script"
        else
            bash "$script"
        fi
    done < <(find "$dir" -maxdepth 1 -type f -name '*.sh' -print0 | sort -z)
}

github_login

git_setup

custom_scripts_setup

claude_setup

copilot_setup

bitbucket_setup

docker_login

gcloud_setup

aws_setup

exec "$@"
