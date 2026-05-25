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
