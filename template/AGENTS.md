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
