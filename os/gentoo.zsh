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

# doas safety shim if someone built without sudo
if ! command -v sudo >/dev/null 2>&1 && command -v doas >/dev/null 2>&1; then
  alias sudo='doas'
fi

# ── Clipboard: delegate to Core's cross-OS scripts ────────────────────────────
command -v clip       >/dev/null && alias pbcopy='clip'
command -v clip-paste >/dev/null && alias pbpaste='clip-paste'

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
# The predicate is Core's (core/zsh/00-tools.zsh :: _core_is_wsl): fork-free, memoised,
# and kept callable at band 80 for exactly this. This layer used to re-derive it.
if _core_is_wsl; then
  alias open='explorer.exe'
  command -v wslview >/dev/null && alias xdg-open='wslview'

  # cdwin — jump to the Windows user profile. A FUNCTION, not an alias gated on $WINHOME:
  # nothing in Core or this layer ever exported WINHOME, so the old alias existed only on a
  # box whose owner had set it by hand in 99-local.zsh — i.e. effectively never.
  #
  # Resolved LAZILY, on first use, never at startup: the only authoritative source is a
  # Windows process (cmd.exe ~200 ms, powershell.exe ~600 ms, measured), which is the whole
  # interactive-shell startup budget several times over, for a path most shells never take.
  # And MEMOISED TO A FILE beside Core's other caches, so the fork is paid once per box, not
  # once per shell as a plain variable memo would. The cached path is re-validated with -d on
  # every read and re-probed if it is gone, so a moved profile self-heals.
  #
  # Resolution order — cheapest first:
  #   $WINHOME      — already exported (by a previous call, or by hand); trusted if it exists
  #   $USERPROFILE  — free: `WSLENV=USERPROFILE/up` on the Windows side hands it over,
  #                   already translated to a /mnt path
  #   the cache     — one file read
  #   cmd.exe       — the probe; run from /mnt/c, because cmd.exe started in a Linux cwd
  #                   warns "UNC paths are not supported" and falls back to C:\Windows
  #   /mnt/c/Users/$USER — last resort; right on the common setup, wrong quietly otherwise
  cdwin() {
    if [[ ! -d ${WINHOME:-} ]]; then
      local cache="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/winhome" up=""
      if [[ -d ${USERPROFILE:-} ]]; then
        up=$USERPROFILE
      elif [[ -s $cache ]]; then
        up="$(<"$cache")"
      fi
      if [[ ! -d $up ]] && (( $+commands[cmd.exe] && $+commands[wslpath] )); then
        up="$(cd /mnt/c 2>/dev/null && cmd.exe /d /c 'echo %USERPROFILE%' 2>/dev/null)"
        up=${up%%$'\r'*}
        [[ -n $up ]] && up="$(wslpath -u "$up" 2>/dev/null)"
        if [[ -d $up ]]; then
          # `>|`: 10-options.zsh sets NO_CLOBBER, under which a plain `>` onto an existing
          # file is a redirection error. Failure to cache is not failure to cd.
          [[ -d ${cache:h} ]] || mkdir -p "${cache:h}" 2>/dev/null
          print -r -- "$up" >| "$cache" 2>/dev/null
        fi
      fi
      [[ -d $up ]] || up="/mnt/c/Users/$USER"
      if [[ ! -d $up ]]; then
        print -u2 "cdwin: could not resolve the Windows profile (tried \$WINHOME, \$USERPROFILE, $cache, cmd.exe, /mnt/c/Users/$USER)"
        return 1
      fi
      export WINHOME=$up
    fi
    cd "$WINHOME"
  }
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
