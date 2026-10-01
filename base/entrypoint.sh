#!/usr/bin/env bash

set -euo pipefail

log() {
    echo "[entrypoint] $*"
}

# Debug-level log line, only emitted when ENTRYPOINT_LOG_LEVEL=debug. Used for
# the decisions that make a re-run cheap (what was found, why it was skipped).
log_debug() {
    if [[ "${ENTRYPOINT_LOG_LEVEL:-info}" == "debug" ]]; then
        echo "[entrypoint] DEBUG: $*"
    fi
}

# Error-level log line, routed to stderr so it stands out from the normal
# lifecycle output in `docker logs` and is easy to grep for.
log_err() {
    echo "[entrypoint] ERROR: $*" >&2
}

# Re-emits an external tool's captured output as clearly-marked entrypoint
# lines, so the tool's own explanation of a failure (an expired token, a
# rejected key, an unreachable host) is never swallowed. Each line is prefixed
# and indented so it reads as the tool speaking, not the entrypoint.
log_tool_output() {
    local output="$1"
    if [[ -z "$output" ]]; then
        log_err "  (the tool produced no output)"
        return
    fi
    local line
    while IFS= read -r line; do
        log_err "  | $line"
    done <<<"$output"
}

# Runs an external command with stdout+stderr captured. On success the output
# is discarded to keep the log readable and 0 is returned. On failure the
# tool's own output is logged under a clear ERROR line and the tool's exit
# status is returned — which, since callers run it unguarded under
# `set -euo pipefail`, aborts container start rather than letting it come up
# with a silently broken integration. Not for pipelines (it feeds no stdin);
# capture those inline instead (see github_login / docker_login).
run_step() {
    local description="$1"
    shift
    local output status=0
    output=$("$@" 2>&1) || status=$?
    if [[ "$status" -ne 0 ]]; then
        log_err "${description} failed (exit ${status}). Tool output:"
        log_tool_output "$output"
        return "$status"
    fi
    return 0
}

# Polls `docker info` for up to 30s. Shared by docker_login() (waiting on
# whatever daemon DOCKER_HOST already points at) and docker_daemon_setup()
# (waiting on the embedded daemon it just started).
wait_for_docker() {
    local attempt
    for attempt in $(seq 1 30); do
        if docker info >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    # Probe once more after the final sleep, so a daemon that comes up during
    # the last interval is not reported as unreachable.
    docker info >/dev/null 2>&1
}

github_login() {
    local token="${GITHUB_TOKEN:-}"

    if [[ -z "$token" ]]; then
        log "Skipping GitHub authentication because GITHUB_TOKEN is not set."
        return
    fi

    export GITHUB_TOKEN="$token"

    # `gh auth status` does a live API call against the token gh is using
    # (the exported GITHUB_TOKEN), so it is the authoritative validity check —
    # an expired or revoked token fails here. Capture its output so the reason
    # is available rather than discarded to /dev/null.
    local status_output status=0
    status_output=$(gh auth status --hostname github.com 2>&1) || status=$?
    if [[ "$status" -eq 0 ]]; then
        log "GitHub CLI is already authenticated for github.com."
        return
    fi

    log "GitHub CLI not yet authenticated for github.com; logging in with the provided token..."
    local login_output login_status=0
    login_output=$(printf '%s' "$token" | gh auth login --hostname github.com --with-token 2>&1) || login_status=$?
    if [[ "$login_status" -ne 0 ]]; then
        log_err "GitHub CLI login failed for github.com (exit ${login_status}). Tool output:"
        log_tool_output "$login_output"
        return "$login_status"
    fi

    # Re-check after login: `gh auth login --with-token` can accept and store a
    # token without proving it is usable, so verify explicitly. This is what
    # turns a silent expired-token failure into a clear, actionable log line.
    local verify_output verify_status=0
    verify_output=$(gh auth status --hostname github.com 2>&1) || verify_status=$?
    if [[ "$verify_status" -ne 0 ]]; then
        log_err "GitHub token was stored but is not usable for github.com (exit ${verify_status}); it is likely expired or lacks the required scopes. Tool output:"
        log_tool_output "$verify_output"
        return "$verify_status"
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

# Installs a global instructions file (CLAUDE.md / AGENTS.md) from $1 to $2,
# without clobbering a file something else has taken over since. The sha256 of
# every copy the entrypoint makes is recorded next to the target; the target is
# only replaced while it still matches that record, i.e. nobody (a sync command,
# `rtk init`, the user) has edited it since. A target with no record is left
# alone too, so containers set up by an older image keep their file.
install_global_md() {
    local agent="$1" src="$2" dest="$3"
    local record="${dest%/*}/.entrypoint-$(basename "$dest").sha256"

    if [[ ! -f "$src" ]]; then
        log "Skipping $agent global MD: $src not found."
        return
    fi

    mkdir -p "$(dirname "$dest")"
    if [[ -f "$dest" ]]; then
        local current recorded
        current=$(sha256sum "$dest" | cut -d' ' -f1)
        recorded=$(cat "$record" 2>/dev/null || true)
        log_debug "$agent global MD: current=$current recorded=${recorded:-none}"
        if [[ "$current" != "$recorded" ]]; then
            log "Keeping $agent global MD $dest: it was modified after the entrypoint installed it."
            return
        fi
        if cmp -s "$src" "$dest"; then
            log "$agent global MD $dest is up to date."
            return
        fi
    fi

    cp "$src" "$dest"
    sha256sum "$dest" | cut -d' ' -f1 >"$record"
    log "$agent global MD installed from $src."
}

# Reports how the MCP server $2 in the JSON config $1 compares to the wanted
# fields $3 (a JSON object, e.g. {"url": ...} or {"command": ..., "args": [...]}).
# Prints "missing", "same" or "changed". Only the wanted fields are compared,
# so tool-specific extras (Copilot's "tools", Claude's "env") don't count.
mcp_state() {
    local file="$1" name="$2" want="$3"
    if [[ ! -f "$file" ]] || ! jq -e --arg name "$name" '.mcpServers[$name] != null' "$file" >/dev/null 2>&1; then
        echo missing
    elif jq -e --arg name "$name" --argjson want "$want" \
        '.mcpServers[$name] as $have | $want | to_entries | all($have[.key] == .value)' "$file" >/dev/null 2>&1; then
        echo same
    else
        echo changed
    fi
}

# Prints the fields a stdio MCP server is stored with: the first word of its
# command line as "command" and the rest as "args".
stdio_mcp_fields() {
    jq -nc --args '{command: $ARGS.positional[0], args: $ARGS.positional[1:]}' -- "$@"
}

# Adds MCP server $3 for agent $1 unless it is already configured the same way.
# $2 is the agent's config file, $4 the wanted fields (see mcp_state), $5 the
# remove command, and the remaining args the add command. A changed server is
# removed and re-added, so edits to setup.json apply on the next run.
ensure_mcp() {
    local agent="$1" file="$2" name="$3" want="$4" remove_cmd="$5"
    shift 5
    local state
    state=$(mcp_state "$file" "$name" "$want")
    log_debug "$agent MCP '$name': $state (wanted $want)"
    case "$state" in
    same)
        log "$agent MCP '$name' already configured, skipping."
        return
        ;;
    changed)
        log "$agent MCP '$name' changed in setup.json, re-adding."
        # shellcheck disable=SC2086
        run_step "Removing $agent MCP '$name'" $remove_cmd "$name"
        ;;
    esac
    run_step "Adding $agent MCP '$name'" "$@"
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
        install_global_md "Claude" "${files_dir}/${global_md}" /root/.claude/CLAUDE.md
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
        ensure_mcp "Claude" /root/.claude.json "$name" "$(jq -nc --arg url "$url" '{url: $url}')" \
            "claude mcp remove --scope user" \
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
        ensure_mcp "Claude" /root/.claude.json "$name" "$(stdio_mcp_fields "${command_args[@]}")" \
            "claude mcp remove --scope user" \
            claude mcp add --scope user --transport stdio "$name" -- "${command_args[@]}"
    done

    # plugins
    count=$(jq '.claude.plugins // [] | length' "$config_file")
    for i in $(seq 0 $((count - 1))); do
        local marketplace_id plugin_id
        marketplace_id=$(jq -r ".claude.plugins[$i].marketplace_id" "$config_file")
        plugin_id=$(jq -r ".claude.plugins[$i].plugin_id" "$config_file")
        log "Installing Claude plugin: $plugin_id from $marketplace_id"
        run_step "Adding Claude plugin marketplace '$marketplace_id'" \
            claude plugin marketplace add --scope user "$marketplace_id"
        run_step "Installing Claude plugin '$plugin_id'" \
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
        ensure_mcp "Copilot" /root/.copilot/mcp-config.json "$name" "$(jq -nc --arg url "$url" '{url: $url}')" \
            "copilot mcp remove" \
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
        ensure_mcp "Copilot" /root/.copilot/mcp-config.json "$name" "$(stdio_mcp_fields "${command_args[@]}")" \
            "copilot mcp remove" \
            copilot mcp add --transport stdio "$name" -- "${command_args[@]}"
    done

    # plugins
    count=$(jq '.copilot.plugins // [] | length' "$config_file")
    for i in $(seq 0 $((count - 1))); do
        local marketplace_id plugin_id
        marketplace_id=$(jq -r ".copilot.plugins[$i].marketplace_id" "$config_file")
        plugin_id=$(jq -r ".copilot.plugins[$i].plugin_id" "$config_file")
        log "Installing Copilot plugin: $plugin_id from $marketplace_id"
        # Unlike Claude's, Copilot's `marketplace add` fails on an already
        # registered marketplace. Its list shows sources as "GitHub: owner/repo".
        if copilot plugin marketplace list --json 2>/dev/null |
            jq -e --arg id "$marketplace_id" 'any(.[]; (.source | split(": ") | last) == $id)' >/dev/null; then
            log "Copilot plugin marketplace '$marketplace_id' already registered, skipping."
        else
            run_step "Adding Copilot plugin marketplace '$marketplace_id'" \
                copilot plugin marketplace add "$marketplace_id"
        fi
        run_step "Installing Copilot plugin '${plugin_id}@${marketplace_id}'" \
            copilot plugin install "${plugin_id}@${marketplace_id}"
    done

    log "Copilot setup completed."
}

# Applies a jq filter to $1 (an opencode.json path) and writes the result
# back in place — jq has no in-place edit flag, so this goes through a temp
# file. Remaining args are passed through to jq (options, then the filter).
# Returns non-zero instead of aborting the entrypoint, so a bad merge degrades
# to "opencode config skipped" like every other setup step rather than stopping
# the container from starting. The result is validated before it replaces the
# target: jq exits 0 and emits nothing when handed an empty file, which would
# otherwise silently install a zero-byte opencode.json.
opencode_json_merge() {
    local target="$1"
    shift
    local tmp
    tmp=$(mktemp "${target}.XXXXXX") || return 1

    if ! jq "$@" "$target" >"$tmp" 2>/dev/null; then
        log "Skipping opencode config merge: jq failed on $target."
        rm -f "$tmp"
        return 1
    fi

    if ! jq -e . "$tmp" >/dev/null 2>&1; then
        log "Skipping opencode config merge: jq produced invalid JSON for $target."
        rm -f "$tmp"
        return 1
    fi

    # Preserve the target's existing mode; mktemp creates 0600.
    chmod --reference="$target" "$tmp" 2>/dev/null || true
    mv "$tmp" "$target"
}

opencode_setup() {
    local config_file="${SETUP_CONFIG:-/entrypoint/setup.json}"
    local files_dir="${SETUP_FILES_DIR:-/entrypoint/files}"

    if [[ ! -f "$config_file" ]]; then
        log "Skipping opencode setup because $config_file is not present."
        return
    fi

    if ! command -v opencode >/dev/null 2>&1; then
        log "Skipping opencode setup because opencode is not installed."
        return
    fi

    mkdir -p /root/.config/opencode

    # global AGENTS.md
    local global_md
    global_md=$(jq -r '.opencode.global_md // empty' "$config_file")
    if [[ -n "$global_md" ]]; then
        install_global_md "opencode" "${files_dir}/${global_md}" /root/.config/opencode/AGENTS.md
    fi

    # skills
    local skills_dir
    skills_dir=$(jq -r '.opencode.skills_dir // empty' "$config_file")
    if [[ -n "$skills_dir" ]]; then
        install_skills "opencode" "${files_dir}/${skills_dir}" /root/.config/opencode/skills
    fi

    # opencode.json (mcp + plugin) — written directly via jq since opencode has
    # no non-interactive add command; merges must be additive so pre-existing
    # keys/entries not mentioned in setup.json survive.
    local opencode_json="/root/.config/opencode/opencode.json"
    # Seed when absent, empty, or not valid JSON — jq treats an empty file as
    # no input and would emit nothing, wiping the file on the first merge.
    if ! jq -e . "$opencode_json" >/dev/null 2>&1; then
        echo '{}' >"$opencode_json"
    fi

    # http mcps
    local count
    count=$(jq '.opencode.http_mcps // [] | length' "$config_file")
    for i in $(seq 0 $((count - 1))); do
        local name url
        name=$(jq -r ".opencode.http_mcps[$i].name" "$config_file")
        url=$(jq -r ".opencode.http_mcps[$i].url" "$config_file")
        log "Adding opencode HTTP MCP: $name -> $url"
        opencode_json_merge "$opencode_json" --arg name "$name" --arg url "$url" \
            '.mcp[$name] = {"type": "remote", "url": $url}' || true
    done

    # stdio mcps
    count=$(jq '.opencode.stdio_mcps // [] | length' "$config_file")
    for i in $(seq 0 $((count - 1))); do
        local name command command_json
        local -a command_args
        name=$(jq -r ".opencode.stdio_mcps[$i].name" "$config_file")
        command=$(jq -r ".opencode.stdio_mcps[$i].command" "$config_file")
        read -ra command_args <<<"$command"
        command_json=$(jq -n --args '$ARGS.positional' -- "${command_args[@]}")
        log "Adding opencode stdio MCP: $name"
        opencode_json_merge "$opencode_json" --arg name "$name" --argjson command "$command_json" \
            '.mcp[$name] = {"type": "local", "command": $command}' || true
    done

    # plugins (flat list of npm package name strings)
    local plugins_json
    plugins_json=$(jq -c '.opencode.plugins // []' "$config_file")
    if [[ "$plugins_json" != "[]" ]]; then
        log "Adding opencode plugins: $(jq -r 'join(", ")' <<<"$plugins_json")"
        opencode_json_merge "$opencode_json" --argjson new "$plugins_json" \
            '.plugin = (((.plugin // []) + $new) | unique)' || true
    fi

    log "opencode setup completed."
}

bitbucket_setup() {
    local user="${BITBUCKET_USER:-}"
    local password="${BITBUCKET_PASSWORD:-}"

    if [[ -z "$user" || -z "$password" ]]; then
        log "Skipping Bitbucket setup because BITBUCKET_USER or BITBUCKET_PASSWORD is not set."
        return
    fi

    if command -v bb >/dev/null 2>&1; then
        log "Configuring Bitbucket CLI credentials..."
        local config_file="${HOME:-/root}/.bitbucket-rest-cli-config.json"
        jq -n --arg username "$user" --arg appPassword "$password" \
            '{auth: {username: $username, appPassword: $appPassword}}' >"$config_file"
        chmod 600 "$config_file"
        log "Bitbucket CLI credentials written to $config_file."
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
    if ! wait_for_docker; then
        # Surface why the daemon is unreachable (permission denied, no such
        # host, ...) instead of just reporting the timeout. This stays a skip
        # rather than a hard failure: an unreachable daemon is usually an
        # environment/timing issue, not a bad credential.
        local info_output
        info_output=$(docker info 2>&1 || true)
        log_err "Skipping Docker registry login: Docker daemon is not reachable. Last 'docker info' output:"
        log_tool_output "$info_output"
        return
    fi

    log "Logging in to Docker registry${registry:+ $registry}..."
    local login_output login_status=0
    if [[ -n "$registry" ]]; then
        login_output=$(printf '%s' "$password" | docker login --username "$user" --password-stdin "$registry" 2>&1) || login_status=$?
    else
        login_output=$(printf '%s' "$password" | docker login --username "$user" --password-stdin 2>&1) || login_status=$?
    fi
    if [[ "$login_status" -ne 0 ]]; then
        log_err "Docker registry login failed (exit ${login_status}). Tool output:"
        log_tool_output "$login_output"
        return "$login_status"
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
    local decode_output decode_status=0
    decode_output=$(printf '%s' "$key_b64" | base64 -d > "$key_file" 2>&1) || decode_status=$?
    if [[ "$decode_status" -ne 0 ]]; then
        log_err "Failed to base64-decode GCLOUD_SERVICE_ACCOUNT_KEY_B64 (exit ${decode_status}). Tool output:"
        log_tool_output "$decode_output"
        return "$decode_status"
    fi
    chmod 600 "$key_file"
    export GOOGLE_APPLICATION_CREDENTIALS="$key_file"

    run_step "Google Cloud service-account activation" \
        gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"

    if [[ -n "$project_id" ]]; then
        run_step "Google Cloud project selection ($project_id)" \
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

    run_step "AWS access key configuration (profile $profile)" \
        aws configure set aws_access_key_id "$access_key_id" --profile "$profile"
    run_step "AWS secret key configuration (profile $profile)" \
        aws configure set aws_secret_access_key "$secret_access_key" --profile "$profile"

    if [[ -n "$session_token" ]]; then
        run_step "AWS session token configuration (profile $profile)" \
            aws configure set aws_session_token "$session_token" --profile "$profile"
    fi

    if [[ -n "$region" ]]; then
        run_step "AWS region configuration (profile $profile)" \
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
        # Custom scripts stream their own output live (not captured), so their
        # logging is preserved as-is. Failure is still made unmistakable: name
        # the failing script and its exit status, then abort so a broken
        # bootstrap script does not pass unnoticed.
        local script_status=0
        if [[ -x "$script" ]]; then
            "$script" || script_status=$?
        else
            bash "$script" || script_status=$?
        fi
        if [[ "$script_status" -ne 0 ]]; then
            log_err "Custom script failed: $script (exit ${script_status})."
            return "$script_status"
        fi
    done < <(find "$dir" -maxdepth 1 -type f -name '*.sh' -print0 | sort -z)
}

# Set to true by docker_daemon_setup() once supervisord is running, so the
# shutdown path below knows whether there is a daemon to stop gracefully.
DOCKER_DAEMON_STARTED=false

docker_daemon_setup() {
    local config_file="${SETUP_CONFIG:-/entrypoint/setup.json}"

    if [[ ! -f "$config_file" ]]; then
        log "Skipping Docker daemon setup because $config_file is not present."
        return
    fi

    # Fail soft on unreadable config: this runs on every container start, so an
    # unguarded jq would turn a malformed setup.json into a boot failure for an
    # already-initialized container rather than a skipped step.
    local enabled
    if ! enabled=$(jq -r '.docker.enabled // false' "$config_file" 2>/dev/null); then
        log "Skipping Docker daemon setup because $config_file is not valid JSON."
        return
    fi

    if [[ "$enabled" != "true" ]]; then
        log "Skipping Docker daemon setup because docker.enabled is not true in $config_file."
        return
    fi

    # An explicitly set DOCKER_HOST wins over the embedded daemon. It is
    # inherited by `docker exec` sessions straight from the container
    # environment and takes precedence over the CLI's default socket, so
    # starting the embedded daemon anyway would leave the entrypoint talking to
    # one daemon and the developer's shell to another. Deferring keeps the
    # external-daemon workflow (the docker:dind sidecar in examples/dind/)
    # working exactly as it does today.
    if [[ -n "${DOCKER_HOST:-}" ]]; then
        log "DOCKER_HOST is set to '${DOCKER_HOST}'; using that daemon instead of the embedded one."
        log "Unset DOCKER_HOST if you want the embedded daemon that docker.enabled requests."
        return
    fi

    # The daemon listens on /var/run/docker.sock, which is where the Docker CLI
    # looks by default, so nothing needs to point the client at it - including
    # `docker exec` shells, which would not inherit an exported DOCKER_HOST.

    log "Starting supervisord to launch the embedded Docker daemon..."
    if ! supervisord -c /etc/supervisor/supervisord.conf; then
        log "Failed to launch supervisord; continuing without the embedded Docker daemon."
        return
    fi

    DOCKER_DAEMON_STARTED=true

    log "Waiting for the embedded Docker daemon to become reachable..."
    if wait_for_docker; then
        log "Embedded Docker daemon is reachable."
    else
        log "Embedded Docker daemon did not become reachable within the timeout; continuing anyway."
    fi
}

# Runs on every container start (not gated by INITIALIZED_MARKER) and must
# complete before the marker-guarded block below, because docker_login()
# inside that block polls the daemon this function starts. See the plan's
# Key Technical Decisions for why this ordering matters.
docker_daemon_setup

INITIALIZED_MARKER="${SETUP_INITIALIZED_MARKER:-/root/.entrypoint_initialized}"

# setup.json's setup.run: "once" (default) runs the setup below only on the
# first start of a container; "always" re-runs it on every start, so changes to
# setup.json, the mounted files or the custom scripts apply on a plain restart.
# Every built-in step is safe to repeat; custom scripts must be too.
SETUP_RUN=$(jq -r '.setup.run // "once"' "${SETUP_CONFIG:-/entrypoint/setup.json}" 2>/dev/null || echo once)
log_debug "setup.run=$SETUP_RUN, marker $INITIALIZED_MARKER $([[ -f "$INITIALIZED_MARKER" ]] && echo present || echo absent)"

if [[ -f "$INITIALIZED_MARKER" && "$SETUP_RUN" != "always" ]]; then
    log "Container already initialized, skipping setup."
else
    if [[ -f "$INITIALIZED_MARKER" ]]; then
        log "Container already initialized, re-running setup (setup.run is \"always\")."
    fi
    github_login

    git_setup

    claude_setup

    copilot_setup

    opencode_setup

    bitbucket_setup

    docker_login

    gcloud_setup

    aws_setup

    custom_scripts_setup

    touch "$INITIALIZED_MARKER"
    log "Setup completed. Marker written to $INITIALIZED_MARKER."
fi

if [[ "$DOCKER_DAEMON_STARTED" != true ]]; then
    # Default path, unchanged: the container's CMD replaces this shell and
    # becomes PID 1, so it receives SIGTERM from `docker stop` directly.
    exec "$@"
fi

# The embedded daemon needs a graceful stop, and only PID 1 is signalled on
# `docker stop`. Keeping this shell as PID 1 lets it stop dockerd through
# supervisor (honouring the stopsignal/stopwaitsecs/stopasgroup settings in
# supervisord.conf) before the container goes away, instead of dockerd being
# SIGKILLed mid-write with /var/lib/docker on a volume.
#
# This costs manual signal and exit-code forwarding, which is why it is scoped
# to the opt-in Docker path rather than applied to every container.
#
# Give the container enough time to finish: `stop_grace_period` in Compose or
# `--stop-timeout` on docker run must exceed supervisord's stopwaitsecs, or the
# shutdown below is itself SIGKILLed partway through. See examples/embedded/.
shutdown_daemon() {
    log "Stopping the embedded Docker daemon before shutdown..."
    supervisorctl -c /etc/supervisor/supervisord.conf stop dockerd >/dev/null 2>&1 ||
        log "Could not stop dockerd cleanly via supervisor."
    kill -TERM "$child" 2>/dev/null || true
}

"$@" &
child=$!
trap shutdown_daemon TERM INT

# `wait` returns as soon as a trapped signal arrives, so wait again to reap the
# child and pick up its real exit status.
wait "$child"
exit_code=$?
if [[ $exit_code -gt 128 ]]; then
    wait "$child" 2>/dev/null
    exit_code=$?
fi
exit "$exit_code"
