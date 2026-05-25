# Dev Workspaces Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a project-based dev-workspace system — a minimal prebuilt base image, a copyable `.devcontainer/` template, supporting scripts, and migration of two existing generic devcontainers onto it.

**Architecture:** One `workspace-base:latest` Docker image (CLI tools + uv + nvm/pnpm + agents + guards) built from a Dockerfile in this repo. Projects become workspaces by copying `template/.devcontainer/` (which is `FROM workspace-base`). Persistent terminal containers via the `devcontainers/cli`; secrets injected host-side via `op inject` → `--remote-env`, never persisted. Defense-in-depth: gitleaks pre-commit, a 5-day package-age guard, per-workspace cache volumes, and an opt-in egress firewall.

**Tech Stack:** Docker, devcontainers/cli (`npm i -g @devcontainers/cli`), bash, uv, nvm/pnpm, gitleaks, iptables/ipset (firewall), 1Password CLI (`op`).

**Verification note:** This is infrastructure, not application code — there is no unit-test harness. Each task's "test" is a **build-or-run verification**: build the artifact, run a concrete command, and assert the observed output. Treat the `Expected:` lines as the pass condition.

**Repo:** `~/Documents/Github/personal/dev-workspaces` (git already initialized, branch `main`).

---

## File Structure

| File | Responsibility |
|---|---|
| `images/Dockerfile.base` | Defines `workspace-base:latest` — all baked-in tooling |
| `images/init-firewall.sh` | Opt-in egress allowlist script (run at container start) |
| `scripts/pkg-age-check` | Rejects packages published ≤ 5 days ago |
| `scripts/install-shims.sh` | Bash functions wrapping `uv add`/`npm install`/`pnpm add` |
| `template/.devcontainer/devcontainer.json` | The copyable workspace definition |
| `template/.githooks/pre-commit` | gitleaks secret scan on staged changes |
| `template/AGENTS.md` | Standing safety/preference rules at project root |
| `dotfiles/starship.toml` | Prompt config (mounted read-only) |
| `dotfiles/bash_aliases.sh` | Shell fragment sourced in-container |
| `README.md` | Usage: build image, create a workspace, secret snippet, commands |

---

## Task 1: Repo skeleton + README

**Files:**
- Create: `README.md`
- Create: `images/`, `scripts/`, `template/.devcontainer/`, `template/.githooks/`, `dotfiles/` (via files below)

- [ ] **Step 1: Create directory skeleton**

Run:
```bash
cd ~/Documents/Github/personal/dev-workspaces
mkdir -p images scripts template/.devcontainer template/.githooks dotfiles
```

- [ ] **Step 2: Write the README**

Create `README.md`:
````markdown
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
````

- [ ] **Step 3: Commit**

```bash
cd ~/Documents/Github/personal/dev-workspaces
git add README.md
git commit -m "docs: add dev-workspaces README and skeleton"
```

---

## Task 2: Package-age guard script

**Files:**
- Create: `scripts/pkg-age-check`

- [ ] **Step 1: Write the script**

Create `scripts/pkg-age-check` (make a note to `chmod +x` in step 2):
```bash
#!/usr/bin/env bash
# pkg-age-check <ecosystem> <package> [version]
# Exit 0 if the package's relevant release is OLDER than MIN_AGE_DAYS (default 5).
# Exit 1 if it is too new or its age cannot be determined.
set -euo pipefail

MIN_AGE_DAYS="${PKG_MIN_AGE_DAYS:-5}"
eco="${1:-}"; pkg="${2:-}"; ver="${3:-}"

if [ -z "$eco" ] || [ -z "$pkg" ]; then
  echo "usage: pkg-age-check <npm|pypi> <package> [version]" >&2
  exit 2
fi

now_epoch=$(date -u +%s)
iso_to_epoch() { date -u -d "$1" +%s 2>/dev/null || echo ""; }

published=""
case "$eco" in
  npm)
    # registry returns time map keyed by version; fall back to latest
    meta=$(curl -fsSL "https://registry.npmjs.org/${pkg}") || { echo "pkg-age-check: cannot fetch $pkg" >&2; exit 1; }
    if [ -n "$ver" ]; then
      published=$(printf '%s' "$meta" | jq -r --arg v "$ver" '.time[$v] // empty')
    fi
    if [ -z "$published" ]; then
      latest=$(printf '%s' "$meta" | jq -r '."dist-tags".latest')
      published=$(printf '%s' "$meta" | jq -r --arg v "$latest" '.time[$v] // empty')
    fi
    ;;
  pypi)
    meta=$(curl -fsSL "https://pypi.org/pypi/${pkg}/json") || { echo "pkg-age-check: cannot fetch $pkg" >&2; exit 1; }
    if [ -n "$ver" ]; then
      published=$(printf '%s' "$meta" | jq -r --arg v "$ver" '.releases[$v][0].upload_time_iso_8601 // empty')
    fi
    if [ -z "$published" ]; then
      published=$(printf '%s' "$meta" | jq -r '.urls[0].upload_time_iso_8601 // empty')
    fi
    ;;
  *)
    echo "pkg-age-check: unknown ecosystem '$eco'" >&2; exit 2 ;;
esac

if [ -z "$published" ]; then
  echo "pkg-age-check: could not determine publish date for $pkg" >&2
  exit 1
fi

pub_epoch=$(iso_to_epoch "$published")
[ -z "$pub_epoch" ] && { echo "pkg-age-check: bad date '$published'" >&2; exit 1; }

age_days=$(( (now_epoch - pub_epoch) / 86400 ))
if [ "$age_days" -lt "$MIN_AGE_DAYS" ]; then
  echo "BLOCKED: ${eco}:${pkg} published ${age_days}d ago (< ${MIN_AGE_DAYS}d minimum)" >&2
  exit 1
fi
echo "ok: ${eco}:${pkg} is ${age_days}d old"
```

- [ ] **Step 2: Make executable and run against a known-old package**

Run:
```bash
chmod +x scripts/pkg-age-check
./scripts/pkg-age-check pypi requests 2.31.0
```
Expected: prints `ok: pypi:requests is <N>d old` and exits 0 (requests 2.31.0 is years old).

- [ ] **Step 3: Run against the npm path**

Run:
```bash
./scripts/pkg-age-check npm left-pad 1.3.0; echo "exit=$?"
```
Expected: prints `ok: npm:left-pad is <N>d old` and `exit=0`.

- [ ] **Step 4: Verify the too-new branch logic with a forced threshold**

Run:
```bash
PKG_MIN_AGE_DAYS=999999 ./scripts/pkg-age-check pypi requests 2.31.0; echo "exit=$?"
```
Expected: prints `BLOCKED: pypi:requests published <N>d ago (< 999999d minimum)` and `exit=1`.

- [ ] **Step 5: Commit**

```bash
git add scripts/pkg-age-check
git commit -m "feat: add pkg-age-check supply-chain guard"
```

---

## Task 3: Install shims

**Files:**
- Create: `scripts/install-shims.sh`

- [ ] **Step 1: Write the shims**

Create `scripts/install-shims.sh`:
```bash
# Sourced in interactive shells inside the workspace. Wraps package installs
# so each named package is age-checked before the real command runs.
# Direct-add paths only; transitive deps are not gated (see design §7).

_age_guard() { # _age_guard <eco> <pkg...>
  local eco="$1"; shift
  local p
  for p in "$@"; do
    case "$p" in -*) continue ;; esac          # skip flags
    p="${p%@*}"; p="${p%%[><=~^]*}"            # strip version specifiers
    [ -z "$p" ] && continue
    pkg-age-check "$eco" "$p" || return 1
  done
}

uv() {
  if [ "${1:-}" = "add" ]; then
    shift; _age_guard pypi "$@" || return 1
    command uv add "$@"
  else
    command uv "$@"
  fi
}

pnpm() {
  if [ "${1:-}" = "add" ] || [ "${1:-}" = "install" ] && [ "$#" -gt 1 ]; then
    local sub="$1"; shift; _age_guard npm "$@" || return 1
    command pnpm "$sub" "$@"
  else
    command pnpm "$@"
  fi
}

npm() {
  if { [ "${1:-}" = "install" ] || [ "${1:-}" = "i" ]; } && [ "$#" -gt 1 ]; then
    local sub="$1"; shift; _age_guard npm "$@" || return 1
    command npm "$sub" "$@"
  else
    command npm "$@"
  fi
}
```

- [ ] **Step 2: Verify the guard logic in isolation**

Run:
```bash
bash -c '
  pkg-age-check() { echo "checked $2"; [ "$2" = "evilpkg" ] && return 1 || return 0; }
  export -f pkg-age-check
  source scripts/install-shims.sh
  command() { echo "REAL: $*"; }   # stub the real binary
  uv add requests httpx
  echo "---"
  uv add evilpkg; echo "blocked exit=$?"
'
```
Expected: prints `checked requests`, `checked httpx`, then `REAL: uv add requests httpx`; after `---` prints `checked evilpkg` and `blocked exit=1` (the real command never runs).

- [ ] **Step 3: Commit**

```bash
git add scripts/install-shims.sh
git commit -m "feat: add age-guard install shims for uv/npm/pnpm"
```

---

## Task 4: Dotfiles

**Files:**
- Create: `dotfiles/starship.toml`
- Create: `dotfiles/bash_aliases.sh`

- [ ] **Step 1: Seed starship.toml from host (or minimal default)**

Run:
```bash
if [ -f ~/.config/starship.toml ]; then
  cp ~/.config/starship.toml dotfiles/starship.toml
else
  printf 'add_newline = true\n' > dotfiles/starship.toml
fi
test -s dotfiles/starship.toml && echo "starship.toml present"
```
Expected: prints `starship.toml present`.

- [ ] **Step 2: Write the bash fragment**

Create `dotfiles/bash_aliases.sh`:
```bash
# Sourced inside the workspace to make the shell feel like home.
export STARSHIP_CONFIG=/etc/skel-dotfiles/starship.toml
command -v starship >/dev/null 2>&1 && eval "$(starship init bash)"

# Ubuntu-name parity for tools that differ on the host.
alias fd='fdfind'
alias bat='batcat'

# Age-guarded installs (functions defined in install-shims.sh).
[ -f /usr/local/lib/install-shims.sh ] && . /usr/local/lib/install-shims.sh
```

- [ ] **Step 3: Commit**

```bash
git add dotfiles/
git commit -m "feat: add dotfiles (starship + bash fragment)"
```

---

## Task 5: Base image Dockerfile

**Files:**
- Create: `images/Dockerfile.base`

- [ ] **Step 1: Write the Dockerfile**

Create `images/Dockerfile.base`:
```dockerfile
FROM debian:bookworm-slim

ARG NVM_VERSION=v0.40.4
ARG NODE_VERSION=24
ENV DEBIAN_FRONTEND=noninteractive \
    NVM_DIR=/usr/local/nvm \
    HOME=/home/vscode

# 1. Base CLI tooling
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git bash sudo \
      ripgrep fd-find bat fzf jq tree \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s "$(command -v fdfind)" /usr/local/bin/fd \
    && ln -s "$(command -v batcat)" /usr/local/bin/bat

# 2. Non-root user (UID adjusted at runtime via updateRemoteUserUID)
RUN useradd -m -s /bin/bash -u 1000 vscode \
    && echo 'vscode ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/vscode

# 3. starship + just + gitleaks (pinned)
RUN curl -fsSL https://starship.rs/install.sh | sh -s -- -y \
    && curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh \
       | bash -s -- --to /usr/local/bin \
    && GL_VER=8.21.2 \
    && curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GL_VER}/gitleaks_${GL_VER}_linux_x64.tar.gz" \
       | tar -xz -C /usr/local/bin gitleaks

# 4. uv (Python) — system-wide
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# 5. nvm + Node + pnpm (corepack), npm hardened
RUN mkdir -p "$NVM_DIR" \
    && curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash \
    && . "$NVM_DIR/nvm.sh" \
    && nvm install "$NODE_VERSION" \
    && nvm alias default "$NODE_VERSION" \
    && corepack enable && corepack prepare pnpm@latest --activate \
    && npm config set ignore-scripts true --location=global

# 6. Agents — Claude Code + pi-coding-agent (scripts ignored)
RUN . "$NVM_DIR/nvm.sh" \
    && npm install -g --ignore-scripts @anthropic-ai/claude-code @earendil-works/pi-coding-agent

# 7. Make node/npm/pnpm available on PATH for non-login shells
RUN ln -s "$NVM_DIR/versions/node/$(. $NVM_DIR/nvm.sh && nvm version default)/bin/"* /usr/local/bin/ || true

# 8. Repo-provided scripts + dotfiles (build context = repo root)
COPY scripts/pkg-age-check /usr/local/bin/pkg-age-check
COPY scripts/install-shims.sh /usr/local/lib/install-shims.sh
COPY dotfiles/ /etc/skel-dotfiles/
RUN chmod +x /usr/local/bin/pkg-age-check \
    && echo '. /etc/skel-dotfiles/bash_aliases.sh' >> /home/vscode/.bashrc \
    && chown -R vscode:vscode /home/vscode

USER vscode
WORKDIR /workspace
CMD ["sleep", "infinity"]
```

- [ ] **Step 2: Add a justfile build target**

Create `justfile` at repo root:
```make
# build the base image (context = repo root so COPY paths resolve)
build-base:
    docker build -t workspace-base:latest -f images/Dockerfile.base .
```

- [ ] **Step 3: Build the image**

Run (from repo root):
```bash
docker build -t workspace-base:latest -f images/Dockerfile.base .
```
Expected: build completes with `naming to docker.io/library/workspace-base:latest`.

- [ ] **Step 4: Verify every baked-in tool resolves**

Run:
```bash
docker run --rm workspace-base:latest bash -lc '
  for t in rg fd bat fzf jq tree git starship just gitleaks uv node npm pnpm pkg-age-check claude; do
    command -v "$t" >/dev/null && echo "ok: $t" || echo "MISSING: $t"
  done
  npm config get ignore-scripts'
```
Expected: `ok:` for every tool listed, no `MISSING:`, and the last line prints `true`.

- [ ] **Step 5: Commit**

```bash
git add images/Dockerfile.base justfile
git commit -m "feat: add workspace-base image and build target"
```

---

## Task 6: Egress firewall script

**Files:**
- Create: `images/init-firewall.sh`

- [ ] **Step 1: Write the firewall script**

Create `images/init-firewall.sh`:
```bash
#!/usr/bin/env bash
# Opt-in egress allowlist. Requires --cap-add=NET_ADMIN. Default-deny outbound,
# allow DNS + loopback + an allowlist of hosts. Reads extra hosts (one per line)
# from ALLOWLIST_FILE if set (default /etc/workspace-allowlist).
set -euo pipefail

ALLOWLIST_FILE="${ALLOWLIST_FILE:-/etc/workspace-allowlist}"
DEFAULT_HOSTS=(registry.npmjs.org pypi.org files.pythonhosted.org github.com api.github.com codeload.github.com objects.githubusercontent.com)

command -v iptables >/dev/null || { echo "iptables missing; install in image or skip firewall" >&2; exit 1; }

iptables -F OUTPUT
iptables -P OUTPUT DROP
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT      # DNS
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

hosts=("${DEFAULT_HOSTS[@]}")
[ -f "$ALLOWLIST_FILE" ] && while IFS= read -r h; do [ -n "$h" ] && hosts+=("$h"); done < "$ALLOWLIST_FILE"

for h in "${hosts[@]}"; do
  for ip in $(getent ahostsv4 "$h" | awk '{print $1}' | sort -u); do
    iptables -A OUTPUT -p tcp -d "$ip" --dport 443 -j ACCEPT
    iptables -A OUTPUT -p tcp -d "$ip" --dport 80 -j ACCEPT
  done
done
echo "firewall: egress locked to ${#hosts[@]} allowed host(s)"
```

- [ ] **Step 2: Verify the script is syntactically valid**

Run:
```bash
chmod +x images/init-firewall.sh
bash -n images/init-firewall.sh && echo "syntax ok"
```
Expected: prints `syntax ok`.

- [ ] **Step 3: Verify it runs end-to-end in a privileged container**

Run:
```bash
docker run --rm --cap-add=NET_ADMIN \
  -v "$PWD/images/init-firewall.sh:/tmp/fw.sh:ro" \
  workspace-base:latest \
  bash -lc 'sudo apt-get update -qq && sudo apt-get install -y -qq iptables >/dev/null && sudo bash /tmp/fw.sh'
```
Expected: prints `firewall: egress locked to N allowed host(s)` with N ≥ 7. (Note: documents that `iptables` must be installed for the opt-in firewall; recorded in the README/AGENTS as a per-workspace prerequisite.)

- [ ] **Step 4: Commit**

```bash
git add images/init-firewall.sh
git commit -m "feat: add opt-in egress allowlist firewall"
```

---

## Task 7: Devcontainer template + pre-commit hook + AGENTS.md

**Files:**
- Create: `template/.devcontainer/devcontainer.json`
- Create: `template/.githooks/pre-commit`
- Create: `template/AGENTS.md`

- [ ] **Step 1: Write devcontainer.json**

Create `template/.devcontainer/devcontainer.json`:
```jsonc
{
  "name": "workspace",
  "image": "workspace-base:latest",
  "workspaceFolder": "/workspace",
  "workspaceMount": "source=${localWorkspaceFolder},target=/workspace,type=bind,consistency=cached",
  "remoteUser": "vscode",
  "updateRemoteUserUID": true,
  "overrideCommand": true,
  "init": true,

  "runArgs": [
    "--cap-drop=ALL",
    "--security-opt=no-new-privileges",
    "--pids-limit=2048",
    "--memory=4g",
    "--cpus=2"
  ],

  "mounts": [
    "source=ws-uv-cache-${devcontainerId},target=/home/vscode/.cache/uv,type=volume",
    "source=ws-npm-cache-${devcontainerId},target=/home/vscode/.npm,type=volume",
    "source=ws-pnpm-store-${devcontainerId},target=/home/vscode/.local/share/pnpm/store,type=volume",
    "source=ws-bun-cache-${devcontainerId},target=/home/vscode/.cache/bun,type=volume",
    "source=${localEnv:HOME}/.config/starship.toml,target=/etc/skel-dotfiles/starship.toml,type=bind,readonly"
  ],

  "containerEnv": {
    "NPM_CONFIG_IGNORE_SCRIPTS": "true",
    "PIP_DISABLE_PIP_VERSION_CHECK": "1"
  },

  "customizations": {
    "vscode": {
      "extensions": [],
      "settings": {
        "terminal.integrated.defaultProfile.linux": "bash",
        "git.enableCommitSigning": false,
        "telemetry.telemetryLevel": "off"
      }
    }
  }
}
```

> **Opt-in firewall:** to enable for a workspace, add the native
> `"capAdd": ["NET_ADMIN"]` property (keep `--cap-drop=ALL` in `runArgs`),
> mount `init-firewall.sh`, and add a `postStartCommand` that runs
> `sudo bash /usr/local/bin/init-firewall.sh` (postStart, not postCreate, so
> the iptables rules are re-applied on every container start). Left out of the
> default template because it relaxes `--cap-drop=ALL` (design §9).

- [ ] **Step 2: Write the pre-commit hook**

Create `template/.githooks/pre-commit`:
```bash
#!/usr/bin/env bash
# Block commits that contain detectable secrets.
set -euo pipefail
if command -v gitleaks >/dev/null 2>&1; then
  gitleaks protect --staged --redact --no-banner
else
  echo "pre-commit: gitleaks not found; skipping secret scan" >&2
fi
```

- [ ] **Step 3: Write AGENTS.md**

Create `template/AGENTS.md`:
```markdown
# Workspace Rules

This project runs inside an isolated dev workspace. These rules are mandatory.

## Secrets
- Never store secrets in unencrypted form. No plaintext `.env` files.
- Use `.env.tpl` with `op://Vault/Item/field` references; secrets are injected
  at runtime via `op inject` → `--remote-env`. Never commit resolved values.
- A `gitleaks` pre-commit hook will block commits containing secrets.

## Dependencies (supply-chain safety)
- Never install a package published <= 5 days ago. The `uv add` / `npm install`
  / `pnpm add` shims enforce this via `pkg-age-check`; do not bypass with
  `command uv ...`.
- Python: use `uv` only — never `pip`.
- Node: nvm-managed Node + `pnpm`; npm `ignore-scripts` stays on.

## Git
- Commit signing is disabled in-container. Sign on the host (1Password) if needed.
- Keep commits atomic with clear, conventional messages.
```

- [ ] **Step 4: Verify the hook blocks a planted secret**

Run:
```bash
TMP=$(mktemp -d); cd "$TMP"; git init -q
cp ~/Documents/Github/personal/dev-workspaces/template/.githooks/pre-commit .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
# Use a fixture gitleaks actually flags — AWS *documentation example* keys
# (AKIAIOSFODNN7EXAMPLE) are allowlisted in gitleaks' default ruleset and will
# NOT trigger. A synthetic GitHub PAT shape does:
printf 'token=ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > creds.txt
git add creds.txt
docker run --rm -v "$TMP:/w" -w /w workspace-base:latest \
  gitleaks protect --staged --redact --no-banner; echo "exit=$?"
cd - >/dev/null; rm -rf "$TMP"
```
Expected: gitleaks reports a finding and `exit=1` (commit would be blocked). (Run via the image since the host may lack gitleaks.)

- [ ] **Step 5: Commit**

```bash
cd ~/Documents/Github/personal/dev-workspaces
git add template/
git commit -m "feat: add devcontainer template, pre-commit hook, AGENTS.md"
```

---

## Task 8: End-to-end smoke test of a workspace

**Files:** none created — verifies the whole template against a throwaway project.

- [ ] **Step 1: Ensure devcontainer CLI is installed**

Run:
```bash
command -v devcontainer >/dev/null || npm install -g @devcontainers/cli
devcontainer --version
```
Expected: prints a version (e.g. `0.x.x`).

- [ ] **Step 2: Scaffold a throwaway workspace**

Run:
```bash
WS=$(mktemp -d); cd "$WS"; git init -q
cp -r ~/Documents/Github/personal/dev-workspaces/template/.devcontainer .
cp ~/Documents/Github/personal/dev-workspaces/template/AGENTS.md .
echo "smoke-test workspace at $WS"
```
Expected: prints the path; `.devcontainer/devcontainer.json` and `AGENTS.md` exist.

- [ ] **Step 3: Bring the workspace up**

Run:
```bash
devcontainer up --workspace-folder "$WS"
```
Expected: ends with JSON containing `"outcome":"success"`.

- [ ] **Step 4: Verify tooling + cache volumes + project mount inside**

Run:
```bash
devcontainer exec --workspace-folder "$WS" bash -lc '
  uv --version && node --version && pnpm --version && just --version
  test -d /home/vscode/.cache/uv && echo "uv cache mounted"
  touch /workspace/MARKER && ls /workspace/MARKER'
ls "$WS/MARKER" && echo "bind mount confirmed on host"
```
Expected: version lines print, `uv cache mounted`, `/workspace/MARKER` lists inside, and `MARKER` exists on the host (`bind mount confirmed on host`) — proving the project dir is the mount.

- [ ] **Step 5: Verify the secret-injection snippet passes env without writing files**

Run:
```bash
printf 'MYSECRET={{ op://Personal/Example/field }}\n' > "$WS/.env.tpl"
# simulate op inject without 1Password by faking the resolved output:
devcontainer exec --workspace-folder "$WS" --remote-env MYSECRET=resolved-value \
  bash -lc 'echo "in-container: $MYSECRET"'
test ! -f "$WS/.env" && echo "no .env written"
```
Expected: prints `in-container: resolved-value` and `no .env written`. (Confirms `--remote-env` carries secrets and nothing is persisted. With real 1Password, replace `--remote-env MYSECRET=...` with the `$(op inject ...)` snippet from the README.)

- [ ] **Step 6: Tear down the throwaway workspace**

Run:
```bash
docker ps -a --filter "label=devcontainer.local_folder=$WS" -q | xargs -r docker rm -f
rm -rf "$WS"
echo "smoke test torn down"
```
Expected: prints `smoke test torn down`, no container remains.

- [ ] **Step 7: Commit (docs only, if any notes were added)**

No source changes in this task. If smoke testing surfaced fixes, commit them against the relevant task's files with a `fix:` message.

---

## Task 9: Migrate harness_engineering

**Files:**
- Modify: `~/Documents/Github/personal/dev/harness_engineering/.devcontainer/devcontainer.json`
- Delete: `~/Documents/Github/personal/dev/harness_engineering/.devcontainer/Dockerfile` (replaced by base image)

- [ ] **Step 1: Back up the current devcontainer**

Run:
```bash
cd ~/Documents/Github/personal/dev/harness_engineering
cp .devcontainer/devcontainer.json .devcontainer/devcontainer.json.bak
git status --short 2>/dev/null || echo "(not a git repo or clean)"
```
Expected: a `.bak` file exists. (Back up because the existing one builds a custom Dockerfile we are replacing.)

- [ ] **Step 2: Replace with the template, preserving any project-specific extensions**

Run:
```bash
WSREPO=~/Documents/Github/personal/dev-workspaces
cp "$WSREPO/template/.devcontainer/devcontainer.json" .devcontainer/devcontainer.json
cp "$WSREPO/template/AGENTS.md" ./AGENTS.md
cp -r "$WSREPO/template/.githooks" ./.githooks
git config core.hooksPath .githooks 2>/dev/null || true
rm -f .devcontainer/Dockerfile .devcontainer/devcontainer-lock.json
```
Expected: no errors. `Dockerfile` removed; template `devcontainer.json` in place.

- [ ] **Step 3: Verify it comes up on the new base image**

Run:
```bash
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . bash -lc 'uv --version && node --version && echo MIGRATED_OK'
```
Expected: ends with `MIGRATED_OK`.

- [ ] **Step 4: Remove the backup and commit (if the project is a git repo)**

Run:
```bash
rm -f .devcontainer/devcontainer.json.bak
git add -A 2>/dev/null && git commit -m "chore: migrate devcontainer to workspace-base template" 2>/dev/null \
  || echo "(commit skipped — review project repo manually)"
```
Expected: either a commit is made in that repo or the skip message prints (so the engineer reviews it). Do not commit into dev-workspaces.

---

## Task 10: Migrate the two obsidian generic workspaces

**Files:**
- Modify: `~/Documents/Github/chaoscodedsystems/obsidian-apps/.devcontainer/devcontainer.json`
- Modify: `~/Documents/Github/personal/dev/obsidian_plugins/template/.devcontainer/devcontainer.json`

- [ ] **Step 1: Inspect both before changing (confirm they are generic, not app stacks)**

Run:
```bash
for d in ~/Documents/Github/chaoscodedsystems/obsidian-apps \
         ~/Documents/Github/personal/dev/obsidian_plugins/template; do
  echo "=== $d ==="; cat "$d/.devcontainer/devcontainer.json"
done
```
Expected: both are generic single-container configs (no compose / app services). If either references `docker-compose` or app DB services, STOP and treat it like AFFiNE (leave it; flag to the user).

- [ ] **Step 2: Migrate each (back up, replace, drop custom Dockerfile)**

Run:
```bash
WSREPO=~/Documents/Github/personal/dev-workspaces
for d in ~/Documents/Github/chaoscodedsystems/obsidian-apps \
         ~/Documents/Github/personal/dev/obsidian_plugins/template; do
  cp "$d/.devcontainer/devcontainer.json" "$d/.devcontainer/devcontainer.json.bak"
  cp "$WSREPO/template/.devcontainer/devcontainer.json" "$d/.devcontainer/devcontainer.json"
  cp "$WSREPO/template/AGENTS.md" "$d/AGENTS.md"
  cp -r "$WSREPO/template/.githooks" "$d/.githooks"
  rm -f "$d/.devcontainer/Dockerfile" "$d/.devcontainer/devcontainer-lock.json"
done
echo "both migrated"
```
Expected: prints `both migrated`.

- [ ] **Step 3: Verify each comes up**

Run:
```bash
for d in ~/Documents/Github/chaoscodedsystems/obsidian-apps \
         ~/Documents/Github/personal/dev/obsidian_plugins/template; do
  devcontainer up --workspace-folder "$d" >/dev/null && \
  devcontainer exec --workspace-folder "$d" bash -lc 'node --version >/dev/null && echo "OK $PWD"'
done
```
Expected: prints `OK /workspace` (or similar) for each.

- [ ] **Step 4: Clean up backups; commit per-repo manually**

Run:
```bash
for d in ~/Documents/Github/chaoscodedsystems/obsidian-apps \
         ~/Documents/Github/personal/dev/obsidian_plugins/template; do
  rm -f "$d/.devcontainer/devcontainer.json.bak"
done
echo "remember to review + commit each project repo separately"
```
Expected: prints the reminder. Commits in those repos are the engineer's call (they belong to other orgs).

---

## Final verification checklist

- [ ] `docker images | grep workspace-base` shows the image.
- [ ] `dev-workspaces` repo committed: README, Dockerfile, justfile, scripts, dotfiles, template (Tasks 1–7).
- [ ] Smoke test (Task 8) passed and torn down cleanly.
- [ ] harness_engineering + both obsidian workspaces come up on the new base image.
- [ ] AFFiNE and t3code devcontainers were NOT touched (`git -C` / file mtime unchanged).
