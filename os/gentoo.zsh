# dotfiles-Gentoo/os/gentoo.zsh
# ──────────────────────────────────────────────────────────────────────────────
# The Gentoo OS-native shell layer. Symlinked to ~/.config/zsh/80-os.zsh and loaded
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
# _cache_eval (00-tools.zsh) — one cheap `source` of a cached file instead of forking each
# generator on EVERY interactive shell. _cache_eval self-guards on the binary being present
# and regenerates only when it's newer than the cache. Falls back to the eager eval if
# this OS layer is sourced without Core's 00-tools.zsh — the fallback
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
# Resolve the repo from THIS file rather than assuming a clone path. This layer is
# reached as ~/.config/zsh/80-os.zsh, a symlink into the repo, so %N gives the path
# it was sourced as and :A resolves it through the symlink to the real file; two
# :h strip /os/gentoo.zsh back to the repo root. The old form hard-coded
# ~/dotfiles-Gentoo and was simply wrong on any box that clones anywhere else —
# `dotsync` then cd'd nowhere with no hint as to why.
_gentoo_repo="${${(%):-%N}:A:h:h}"
if [[ -d "$_gentoo_repo/os" && -f "$_gentoo_repo/bootstrap.sh" ]]; then
  alias dotsync="cd ${(q)_gentoo_repo}"
else
  alias dotsync='cd "$HOME/dotfiles-Gentoo"'   # fallback: the documented clone path
fi
unset _gentoo_repo
command -v op >/dev/null 2>&1 && alias opsignin='eval "$(op signin)"'
alias localip='ip -brief -4 addr show scope global'

# ── WSL-only niceties ─────────────────────────────────────────────────────────
if (( _IS_WSL )); then
  alias open='explorer.exe'
  command -v wslview >/dev/null && alias xdg-open='wslview'
  [[ -n "${WINHOME:-}" ]] && alias cdwin='cd "$WINHOME"'
fi

# ── Gentoo ships fd as `fd` — 00-tools.zsh already resolved this. ───────────────

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
# This is a POLICY choice, not a Gentoo fact — it belongs to whoever owns the
# machine, so it is opt-OUT-able and heavily guarded. It stays in this layer for
# now (moving it to 99-local.zsh would silently turn it off for existing boxes),
# but note the boundary: nothing here is Portage-specific.
#
# The old guard was `-z $TMUX && -t 1 && $TERM_PROGRAM != vscode`, which fires for
# far more than a human opening a terminal. Every added condition below is a case
# where attaching a tmux session is actively wrong:
#
#   DOTFILES_NO_AUTOTMUX  — the opt-out. There was none.
#   ZSH_EXECUTION_STRING  — set by `zsh -ic '<cmd>'`. Running ONE command in an
#                           interactive shell (editors, hooks, agents, and
#                           `make doctor` in this very repo) would hijack the
#                           terminal into a session instead of running it.
#   TERM dumb/linux       — a dumb terminal cannot drive tmux; a bare VT is
#                           usually a recovery console, where you want a shell.
#   VSCODE_INJECTION      — VS Code's integrated terminal does not always set
#                           TERM_PROGRAM, so the original check missed it.
#   INSIDE_EMACS          — same story for M-x shell / vterm.
#   CI                    — a CI runner should never attach to anything.
#
# TERM_PROGRAM is expanded with :- because it is frequently unset, and an unset
# parameter is an error under `setopt nounset`.
if [[ -z "${DOTFILES_NO_AUTOTMUX:-}" \
   && -z "${TMUX:-}" \
   && -z "${ZSH_EXECUTION_STRING:-}" \
   && -z "${VSCODE_INJECTION:-}${INSIDE_EMACS:-}${CI:-}" \
   && "${TERM_PROGRAM:-}" != "vscode" \
   && "$TERM" != (dumb|linux) \
   && -t 1 ]] \
   && command -v tmux >/dev/null 2>&1; then
  tmux attach -t main 2>/dev/null || tmux new-session -s main
fi
