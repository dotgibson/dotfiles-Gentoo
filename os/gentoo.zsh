# dotfiles-Gentoo/os/gentoo.zsh
# ──────────────────────────────────────────────────────────────────────────────
# The Gentoo OS-native shell layer. Symlinked to ~/.config/zsh/os.zsh and loaded
# AFTER Core (tools/aliases/functions). Gentoo/Portage-specific only.
#
# No SELinux/AppArmor block (that's a hardened-profile choice, not the default)
# and no flatpak helpers — on Gentoo, Portage is the way.
# Clipboard logic lives in Core's cross-OS `clip`/`clip-paste`; this layer just
# points pbcopy/pbpaste at them.
# ──────────────────────────────────────────────────────────────────────────────
[[ $- == *i* ]] || return 0

[[ -d "$HOME/.local/bin" && ":$PATH:" != *":$HOME/.local/bin:"* ]] && export PATH="$HOME/.local/bin${PATH:+:$PATH}"
[[ -d "$HOME/.cargo/bin" && ":$PATH:" != *":$HOME/.cargo/bin:"* ]] && export PATH="$HOME/.cargo/bin${PATH:+:$PATH}"

_IS_WSL=0
if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
  _IS_WSL=1
elif [[ -r /proc/version ]]; then
  # zsh reads the file directly (no grep/cat fork) — WSL kernels tag /proc/version.
  _pv="$(</proc/version)"; _pv=${_pv:l}
  [[ "$_pv" == *microsoft* || "$_pv" == *wsl* ]] && _IS_WSL=1
  unset _pv
fi

# doas safety shim if someone built without sudo
if ! command -v sudo >/dev/null 2>&1 && command -v doas >/dev/null 2>&1; then
  alias sudo='doas'
fi

# ── Clipboard: delegate to Core's cross-OS scripts ────────────────────────────
command -v clip       >/dev/null && alias pbcopy='clip'
command -v clip-paste >/dev/null && alias pbpaste='clip-paste'

# ── tool completions / shell hooks (parity with other os layers) ─────────────
# direnv/gh emit DETERMINISTIC scripts (the generated hook/completion TEXT is static for a
# given binary; only the runtime hooks vary per-dir/-shell), so route them through Core's
# _cache_eval (tools.zsh) — one cheap `source` of a cached file instead of forking each
# generator on EVERY interactive shell. _cache_eval self-guards on the binary being present
# and regenerates only when it's newer than the cache. Falls back to the eager eval if
# this OS layer is sourced without Core's tools.zsh — the fallback
# keeps direnv's stderr visible, while the cached path suppresses the generator's
# stderr (as _cache_eval does); direnv's per-dir runtime warnings are unaffected.
if (( $+functions[_cache_eval] )); then
  _cache_eval direnv direnv hook zsh
  _cache_eval gh gh completion -s zsh
else
  command -v direnv >/dev/null 2>&1 && eval "$(direnv hook zsh)"
  command -v gh >/dev/null 2>&1 && eval "$(gh completion -s zsh 2>/dev/null)"
fi

# ── conveniences ──────────────────────────────────────────────────────────────
alias dotsync='cd "$HOME/dotfiles-Gentoo"'
command -v op >/dev/null 2>&1 && alias opsignin='eval "$(op signin)"'
alias localip='ip -brief -4 addr show scope global'

# ── WSL-only niceties ─────────────────────────────────────────────────────────
if (( _IS_WSL )); then
  alias open='explorer.exe'
  command -v wslview >/dev/null && alias xdg-open='wslview'
  [[ -n "${WINHOME:-}" ]] && alias cdwin='cd "$WINHOME"'
fi

# ── Gentoo ships fd as `fd` — tools.zsh already resolved this. ───────────────

# ── Portage / emerge quality-of-life ──────────────────────────────────────────
# Installs default to --ask so you SEE the dep/USE plan before committing —
# this is the Gentoo habit, and where the USE-flag learning happens.
alias emi='sudo emerge -av'                 # install (ask, verbose)
alias emu='sudo emerge -auvDN @world'       # update the whole @world set (ask)
alias emr='sudo emerge -av --depclean'      # remove + clean orphaned deps (ask!)
alias emsync='sudo emerge --sync'           # sync the Portage tree (slow)
alias emsearch='emerge -s'                  # search (eix below is faster)
alias embelongs='equery belongs'            # which package owns a file (gentoolkit)
alias emuses='equery uses'                  # show a package's USE flags
# After a world update Portage often asks for two follow-ups — keep them handy:
alias empreserved='sudo emerge @preserved-rebuild'  # rebuild against new libs
alias emconf='sudo dispatch-conf'                   # merge pending /etc config updates
alias gnews='sudo eselect news read'                # Portage news (READ these)
# eix = fast indexed search (app-portage/eix). `eix-sync` syncs + updates index.
command -v eix >/dev/null 2>&1 && alias emsearch='eix'

unset _IS_WSL

# ── auto-start/attach tmux for interactive terminals ─────────────────────────
if command -v tmux >/dev/null 2>&1 \
   && [[ -z "$TMUX" && -t 1 && "$TERM_PROGRAM" != "vscode" ]]; then
  tmux attach -t main 2>/dev/null || tmux new-session -s main
fi
