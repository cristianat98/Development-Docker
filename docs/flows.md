# Flows

## Container start

```mermaid
flowchart TD
    start([container start]) --> daemon{docker.enabled<br/>and no DOCKER_HOST?}
    daemon -- yes --> dockerd[Start dockerd via supervisord<br/>and wait for it]
    daemon -- no --> gate
    dockerd --> gate
    gate{"marker present<br/>and setup.run != always?"}
    gate -- yes --> skip[Skip setup]
    gate -- no --> setup[github_login, git_setup,<br/>claude_setup, copilot_setup, opencode_setup,<br/>bitbucket_setup, docker_login,<br/>gcloud_setup, aws_setup,<br/>custom_scripts_setup]
    setup --> fail{any step failed?}
    fail -- yes --> abort([Exit non-zero: container does not start])
    fail -- no --> marker[touch marker]
    marker --> cmd
    skip --> cmd
    cmd{embedded dockerd started?}
    cmd -- no --> exec([exec CMD as PID 1])
    cmd -- yes --> child([Run CMD as a child; on SIGTERM<br/>stop dockerd, then the child])
```

## Adding an MCP server (ensure_mcp)

Used for Claude (`~/.claude.json`) and Copilot (`~/.copilot/mcp-config.json`), for both HTTP
(`url`) and stdio (`command` + `args`) servers.

```mermaid
flowchart TD
    start([ensure_mcp name, wanted fields]) --> state{mcp_state in the<br/>agent's config file}
    state -- same --> skip([Skip: already configured])
    state -- changed --> remove[mcp remove name]
    remove --> add
    state -- missing --> add[mcp add name ...]
    add --> done([Done])
```

## Installing a global instructions file (install_global_md)

Used for Claude's `CLAUDE.md` and opencode's `AGENTS.md`.

```mermaid
flowchart TD
    start([install_global_md src, dest]) --> src{src exists?}
    src -- no --> skipsrc([Skip: source not found])
    src -- yes --> dest{dest exists?}
    dest -- no --> copy
    dest -- yes --> own{sha256 of dest ==<br/>recorded sha256?}
    own -- "no (edited since, or no record)" --> keep([Keep dest])
    own -- yes --> same{src == dest?}
    same -- yes --> uptodate([Skip: up to date])
    same -- no --> copy[cp src dest,<br/>record its sha256]
    copy --> done([Done])
```
