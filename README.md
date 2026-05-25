# dev-workspaces

Spin up **safe, isolated dev containers** for any project — with coding agents
([pi](https://github.com/earendil-works/pi-coding-agent) and
[Claude Code](https://github.com/anthropics/claude-code)) preinstalled,
supply-chain guardrails on by default, and one-file egress firewalling.

One workspace = one project directory, running as a persistent container.
Terminal-first via the [`devcontainers/cli`](https://github.com/devcontainers/cli),
and compatible with VS Code "Reopen in Container" since it's just a standard
`devcontainer.json`.

## What you get

- **Agents preloaded:** `pi` and `claude` are baked into the base image.
- **Batteries-included shell:** ripgrep, fd, bat, fzf, jq, tree, git, starship,
  just — plus `uv` (Python), `nvm`/Node/`pnpm` (Node).
- **Isolation:** only the project directory is mounted. The default profile is
  maximally locked — `--cap-drop=ALL` + `no-new-privileges`, so there is **no
  in-container root** (sudo/apt are intentionally non-functional; install deps
  with uv/pnpm). Plus memory/CPU/pid limits.
- **Supply-chain guards:** `npm`/`pnpm`/`uv add` refuse packages published in
  the last 5 days; npm `ignore-scripts` is forced on; a `gitleaks` pre-commit
  hook blocks secret commits.
- **Persistent caches:** per-workspace volumes for uv/npm/pnpm/bun so rebuilds
  are fast and never shared across projects.
- **Opt-in egress firewall:** default-deny outbound with an editable allowlist.

## Prerequisites

- Docker
- Node.js (for the devcontainer CLI)

```bash
npm install -g @devcontainers/cli
```

## Setup

```bash
git clone https://github.com/rororowyourboat/dev-workspaces.git
cd dev-workspaces
just build-base          # builds the workspace-base:latest image
```

> `just build-base` just runs `docker build -t workspace-base:latest -f images/Dockerfile.base .`

## Turn a project into a workspace

From the dev-workspaces checkout, copy the template into your project (adjust
`DW` to wherever you cloned this repo):

```bash
DW=/path/to/dev-workspaces
cd /path/to/your-project

cp -r "$DW/template/.devcontainer" .
cp "$DW/template/AGENTS.md" .
cp -r "$DW/template/.githooks" .
git config core.hooksPath .githooks   # enable the gitleaks pre-commit hook
```

## Daily use

```bash
devcontainer up --workspace-folder .          # build/start the workspace
devcontainer exec --workspace-folder . bash   # open a shell
devcontainer exec --workspace-folder . claude # run an agent
devcontainer exec --workspace-folder . pi     # ...or pi

# tear down:
docker ps -a --filter "label=devcontainer.local_folder=$PWD" -q | xargs -r docker rm -f
```

## Secrets (bring your own manager)

Resolve secrets **on the host** and pass them into a session with
`--remote-env`. They live only in the running process — never written to disk,
never baked into an image layer. Any tool that emits `KEY=value` lines works.

```bash
# 1Password example:
devcontainer exec --workspace-folder . \
  $(op inject -i .env.tpl | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' | sed 's/^/--remote-env /') \
  claude

# Plain (gitignored) env file example:
devcontainer exec --workspace-folder . \
  $(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' .env | sed 's/^/--remote-env /') \
  bash
```

Don't commit resolved secrets. The bundled `gitleaks` pre-commit hook is a
backstop, not a substitute for care.

## Egress firewall (opt-in)

A default-deny outbound firewall is available as a second config. It permits
DNS, loopback, and a built-in allowlist (npm, PyPI, GitHub); you add any extra
hosts your project needs.

```bash
# in your project:
cp .devcontainer/firewall/allowlist.example .devcontainer/firewall/allowlist
$EDITOR .devcontainer/firewall/allowlist     # one hostname per line

devcontainer up --workspace-folder . --config .devcontainer/firewall/devcontainer.json
```

The firewall script (`init-firewall.sh`) is baked into the base image and runs
on every container start via `postStartCommand`. It sets an `ip6tables`
default-deny too, so IPv6 can't bypass the allowlist.

**Capability trade-off:** the firewall needs `sudo` to run `iptables`, which in
turn needs default capabilities + `NET_ADMIN` and *without* `no-new-privileges`.
So the firewall profile is **less hardened than the default** (in-container root
is reachable) — its isolation guarantee comes from the locked egress allowlist
instead of from blocking root. Pick the profile that matches your threat model:
maximum lockdown (default) vs. controlled egress (firewall).

## Customization

- **Prompt/dotfiles:** the image ships a minimal starship config. Override it
  by bind-mounting your own over `/etc/skel-dotfiles/starship.toml`, or use
  `devcontainer up --dotfiles-repository <url> --dotfiles-install-command <cmd>`.
- **Extra tools/deps:** install them inside the workspace, or extend the base
  image with your own `Dockerfile` that does `FROM workspace-base:latest`.
- **Resource limits / package-age threshold:** edit `runArgs` in the
  devcontainer config; set `PKG_MIN_AGE_DAYS` to change the 5-day rule.

See [docs/DESIGN.md](docs/DESIGN.md) for the architecture and rationale.

## License

MIT — see [LICENSE](LICENSE).
