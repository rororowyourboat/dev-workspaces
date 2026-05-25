# dev-workspaces

Project-based, persistent dev containers for isolating client work contexts.
One workspace = one project directory. See
`docs/superpowers/specs/2026-05-25-dev-workspaces-design.md` for the design.

## One-time host setup

```bash
npm install -g @devcontainers/cli   # respects ~/.npmrc ignore-scripts
just build-base                      # builds workspace-base:latest
```

## Turn a project into a workspace

```bash
cd /path/to/project
cp -r ~/Documents/Github/personal/dev-workspaces/template/.devcontainer .
cp ~/Documents/Github/personal/dev-workspaces/template/AGENTS.md .
cp -r ~/Documents/Github/personal/dev-workspaces/template/.githooks .
git config core.hooksPath .githooks   # enable the gitleaks pre-commit hook
```

## Daily commands

```bash
devcontainer up --workspace-folder .          # build/start the workspace
devcontainer exec --workspace-folder . bash   # shell (no secrets)

# shell WITH project secrets (resolved on host, never written to disk):
devcontainer exec --workspace-folder . \
  $(op inject -i .env.tpl | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' | sed 's/^/--remote-env /') \
  bash

# run an agent inside, with secrets:
devcontainer exec --workspace-folder . \
  $(op inject -i .env.tpl | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' | sed 's/^/--remote-env /') \
  claude

# tear down:
docker ps -a --filter "label=devcontainer.local_folder=$PWD" -q | xargs -r docker rm -f
```

## Security model

- Filesystem isolation: only the project dir is mounted.
- Secrets: `op inject` → `--remote-env` at exec time. Never on disk, never in
  an image layer. No plaintext `.env` files — use `.env.tpl` with `op://` refs.
- `gitleaks` pre-commit blocks secret commits.
- `pkg-age-check` blocks installing packages published ≤ 5 days ago.
- Git commit signing is disabled in-container (sign on host via 1Password).
- Optional egress allowlist firewall (see design §9).
