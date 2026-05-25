# Design

dev-workspaces gives each project a disposable, isolated container that feels
like a normal dev box but constrains what code and agents running inside can
reach. The unit of isolation is **one project directory = one container**.

## Components

### Base image (`images/Dockerfile.base` → `workspace-base:latest`)

A single Debian-slim image with everything common baked in: shell tooling
(ripgrep, fd, bat, fzf, jq, tree, git, starship, just), language runtimes
(`uv` for Python; `nvm`/Node/`pnpm` for Node), the `pi` and `claude` coding
agents, the supply-chain scripts, and the firewall script. A non-root `vscode`
user owns the workspace; passwordless sudo is intentional (apt installs and the
firewall need root) — isolation comes from capability dropping and the
single-directory mount, not from blocking in-container root.

Third-party installers (`uv`, `nvm`, starship, just) are fetched via their
official scripts at build time; `pnpm`, Node, `nvm`, and `gitleaks` are pinned.

### Project template (`template/`)

- `.devcontainer/devcontainer.json` — the default workspace: `FROM`
  `workspace-base`, hardened `runArgs` (`--cap-drop=ALL`,
  `no-new-privileges`, memory/CPU/pid limits), `init: true`, and per-workspace
  cache volumes keyed by `${devcontainerId}` (so two projects never share a
  cache).
- `.devcontainer/devcontainer.firewall.json` — same, plus `NET_ADMIN` and a
  `postStartCommand` that runs the egress firewall, with an `allowlist` file
  bind-mounted in.
- `.devcontainer/allowlist.example` — editable host allowlist for the firewall.
- `.githooks/pre-commit` — runs `gitleaks` against staged changes.
- `AGENTS.md` — standing rules dropped at the project root for any agent.

### Supply-chain guards (`scripts/`)

- `pkg-age-check <npm|pypi> <pkg> [version]` — exits non-zero if the package
  was published within `PKG_MIN_AGE_DAYS` (default 5). Queries the registry for
  the publish date; when a version is pinned it checks *that* version and does
  not fall back to latest (so a freshly-published pinned version can't slip
  through). npm scoped names are URL-encoded.
- `install-shims.sh` — bash functions wrapping `uv add` / `npm install` /
  `pnpm add` so each named package is age-checked before the real command runs.
  Direct adds only; transitive dependencies are not gated.

### Egress firewall (`images/init-firewall.sh`)

Opt-in, default-deny outbound. Allows DNS, loopback, established/related, and
TCP 80/443 to a built-in host list plus anything in the allowlist file. Sets an
`ip6tables` default-deny so IPv6 can't bypass the IPv4 allowlist. Resolves
allowlist hostnames to IPs once at start (TOCTOU-acceptable for this use case)
and warns on hosts it cannot resolve rather than silently dropping them.

## Secrets

Never persisted. Secrets are resolved on the host by whatever manager the user
prefers and passed into a session via `devcontainer exec --remote-env`, so they
exist only in the running process. No plaintext secret files are committed; the
`gitleaks` hook is a backstop.

## Non-goals

- Per-language base image variants (one image keeps it simple).
- Gating transitive dependencies by age (only direct adds are checked).
- A bespoke lifecycle wrapper — the standard `devcontainer` CLI is the interface.
- Perfect isolation: this is layered hardening, not a security boundary against
  a determined attacker with code execution inside the container.
