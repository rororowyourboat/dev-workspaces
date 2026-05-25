# Sourced inside the workspace to make the shell feel like home.
export STARSHIP_CONFIG=/etc/skel-dotfiles/starship.toml
command -v starship >/dev/null 2>&1 && eval "$(starship init bash)"

# Ubuntu-name parity for tools that differ on the host.
alias fd='fdfind'
alias bat='batcat'

# Age-guarded installs (functions defined in install-shims.sh).
[ -f /usr/local/lib/install-shims.sh ] && . /usr/local/lib/install-shims.sh
