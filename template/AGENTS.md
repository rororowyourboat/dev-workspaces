# Workspace Rules

This project runs inside an isolated dev workspace. These rules are mandatory.

## Secrets
- Never store secrets in unencrypted form. No plaintext `.env` files committed.
- Resolve secrets on the host and pass them in at runtime via
  `devcontainer exec --remote-env KEY=value`. They live only in the running
  process — never in the image, a build layer, or a committed file. Any secret
  manager works (1Password `op inject`, a gitignored `.env`, Vault, etc.) as
  long as it outputs `KEY=value` lines on the host. Never commit resolved values.
- A `gitleaks` pre-commit hook will block commits containing secrets.

## Dependencies (supply-chain safety)
- Never install a package published <= 5 days ago. The `uv add` / `npm install`
  / `pnpm add` shims enforce this via `pkg-age-check`; do not bypass with
  `command uv ...`.
- Python: use `uv` only — never `pip`.
- Node: nvm-managed Node + `pnpm`; npm `ignore-scripts` stays on.

## Git
- Commit signing is disabled in-container. Sign on the host if needed.
- Keep commits atomic with clear, conventional messages.
