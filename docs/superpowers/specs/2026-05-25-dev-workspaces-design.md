# Dev Workspaces — Design

**Date:** 2026-05-25
**Status:** Approved design, pending implementation plan

## Problem

Work spans multiple clients/orgs (iide, grow, blockscience, personal, bp,
chaoscodedsystems, worklogs). Two isolation mechanisms exist today:

1. **Ephemeral sandbox shell functions** (`~/.config/bash/sandbox.sh`) —
   per-org `docker run --rm` wrappers for dependency operations. Clean,
   keep as-is.
2. **Scattered, inconsistent project devcontainers** — five `.devcontainer/`
   dirs with no shared template; some are real app stacks, some are generic
   "sandboxed-workspace" shells.

Missing: a consistent, *persistent*, project-level workspace story for
isolating work contexts, with baked-in preferences and a familiar template.

## Goal

A **workspace = one project directory** running as a persistent, named
devcontainer, defined by a standard `.devcontainer/` that builds `FROM` a
minimal shared base image. Terminal-first via the `devcontainers/cli`,
VS Code-compatible for free. Isolation is **filesystem + per-project secret
scope**, not network.

## Decisions

| Topic | Decision |
|---|---|
| Workflow | Terminal-first persistent containers |
| Agent placement | Supports Claude/agents **inside**; may also drive from host |
| Isolation unit | **Per project** (one project dir per container) |
| Mechanism | `devcontainer.json` + `devcontainers/cli` (standard, VS Code compat) |
| Base image | Single minimal `workspace-base:latest`, no per-language variants |
| Secrets | Never on disk; `op inject` at exec time, passed via `--remote-env` |
| `ws` wrapper | **None** — use raw `devcontainer` CLI + documented snippets |
| Git signing | **Disabled** inside containers (sign on host via 1Password) |
| Network | On by default (installs/APIs/git) |
| Tooling home | Dedicated repo: `~/Documents/Github/personal/dev-workspaces` |

## Components

### 1. Base image — `workspace-base:latest`

Built locally from `images/Dockerfile.base` in this repo (parallels
`~/.config/bash/sandbox-images/`). Minimal by intent — everything else is
installed per-project by the user.

Contents:
- **Shell/CLI:** bash, ripgrep, fd, bat, fzf, jq, tree, git, starship
- **Python:** `uv` via `curl -LsSf https://astral.sh/uv/install.sh | sh`
- **Node:** `nvm` v0.40.4 via the official install script; `pnpm` via corepack
- **Agents:** `npm install -g --ignore-scripts @earendil-works/pi-coding-agent`
  and the Claude Code CLI
- **npm hardening:** `npm config set ignore-scripts true` globally (mirrors
  host `~/.npmrc`)

No per-language variants. No `op` CLI inside (secrets injected from host).

### 2. Per-project `.devcontainer/` template

Lives in `template/.devcontainer/` in this repo; copied into a project to
make it a workspace. Contains:

- **`devcontainer.json`**
  - `image: workspace-base:latest` (or `build.dockerfile` for project extras)
  - Security hardening (from the existing harness_engineering container):
    `runArgs: ["--cap-drop=ALL", "--security-opt=no-new-privileges",
    "--pids-limit=2048", "--memory=4g", "--cpus=2"]`
  - `workspaceFolder: /workspace`, bind-mount the single project dir
  - `remoteUser: vscode`, `updateRemoteUserUID: true`
  - `customizations.vscode.settings`: `git.enableCommitSigning=false`,
    `telemetry.telemetryLevel=off`, default bash profile
  - `containerEnv`: `NPM_CONFIG_IGNORE_SCRIPTS=true`

- **`AGENTS.md`** dropped at the **project root** with standing rules:
  - Never store secrets in unencrypted form; no plaintext `.env` files —
    use `.env.tpl` with `op://` references
  - **Never install packages published ≤ 5 days ago** (supply-chain guard)
  - Python: `uv` only, never `pip`
  - Node: `nvm`-managed Node + `pnpm`; npm `ignore-scripts` always on
  - Git commit signing happens on host, not in-container

### 3. Secrets — exec-time injection, no wrapper

Secrets are never written to disk and never baked into the image or a build
layer. A documented copy-paste snippet resolves the project's `.env.tpl` via
`op inject` on the host and passes the values into the container session with
`devcontainer exec --remote-env`. Documented in this repo's README; the user
may later alias it. Example pattern:

```bash
# start the persistent workspace
devcontainer up --workspace-folder .

# open a shell with project secrets (resolved on host, never written to disk)
devcontainer exec --workspace-folder . \
  $(op inject -i .env.tpl | sed 's/^/--remote-env /') \
  bash
```

(Exact snippet finalized during implementation; the principle is fixed:
host-side `op inject` → `--remote-env`, nothing persisted.)

### 4. Lifecycle — raw `devcontainer` CLI

- `devcontainer up --workspace-folder .` — build/start persistent container
- `devcontainer exec --workspace-folder . ...` — exec (shell or agent), with
  the secret snippet above when secrets are needed
- `docker stop` / `docker rm` the named container to tear down

## Migration of existing devcontainers

| Project | Action |
|---|---|
| `blockscience/.../t3code` | **Leave** — real bun build stack |
| `personal/dev/AFFiNE` | **Leave** — app dev stack (compose: db/redis/indexer) |
| `personal/dev/harness_engineering` | **Migrate** onto new base image/template |
| `personal/dev/obsidian_plugins/template` | **Migrate** (generic sandbox shell) |
| `chaoscodedsystems/obsidian-apps` | **Migrate** (generic sandbox shell) |

Nothing deleted blindly. App-specific stacks are preserved.

## Out of scope (YAGNI for now)

- A custom `ws` lifecycle wrapper
- Per-language base image variants
- `op` CLI inside containers
- Automated enforcement of the 5-day package-age rule (documented in
  `AGENTS.md`, not machine-enforced yet)
- Changes to the existing `~/.config/bash/sandbox.sh` ephemeral sandboxes

## Repository layout

```
personal/dev-workspaces/
  README.md                      # usage, secret snippet, commands
  images/Dockerfile.base         # workspace-base:latest
  template/.devcontainer/
    devcontainer.json
  template/AGENTS.md             # standing safety/preference rules
  docs/superpowers/specs/        # this design doc + future specs
```
