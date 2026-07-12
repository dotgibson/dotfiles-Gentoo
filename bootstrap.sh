#!/usr/bin/env bash
# dotfiles-Gentoo/bootstrap.sh
# ──────────────────────────────────────────────────────────────────────────────
# Provision a Gentoo box and wire dotfiles. Idempotent. OS-NATIVE layer; Core
# (zsh/tmux/nvim/git) is vendored under core/ and symlinked via core/lib/bootstrap-lib.sh.
# Gentoo is source-based: emerge COMPILES, so a full run can take a while. Two
# mitigations are wired in — the official binhost (--getbinpkg, auto-detected)
# and dev-lang/rust-bin (in packages.txt) instead of compiling Rust from source.
#
# Usage:
#   ./bootstrap.sh                 # sync + emerge atoms + extras + symlinks
#   ./bootstrap.sh --no-sync       # skip the (slow) `emerge --sync`
#   ./bootstrap.sh --links-only    # just (re)create symlinks
#   ./bootstrap.sh --only zsh,nvim # link ONLY these Core module groups
#   ./bootstrap.sh --skip tmux     # link everything EXCEPT these groups
#
# Module groups (for --only/--skip): zsh nvim tmux git prompt tools — they affect
# the wiring steps only, never package provisioning; combine with --links-only to
# re-wire a subset of configs without touching emerge.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
LINKS_ONLY=0
DO_SYNC=1
# --only/--skip are validated by the shared lib (blib_select), which is sourced
# AFTER this loop — so capture the raw values now and apply them below.
ONLY_RAW="" SKIP_RAW="" ONLY_SEEN=0 SKIP_SEEN=0

while [[ $# -gt 0 ]]; do case "$1" in
  --links-only) LINKS_ONLY=1 ;;
  --no-sync) DO_SYNC=0 ;;
  --only) [[ $# -ge 2 ]] || { echo "--only requires module names, e.g. --only zsh,nvim" >&2; exit 1; }; ONLY_RAW="$2"; ONLY_SEEN=1; shift ;;
  --only=*) ONLY_RAW="${1#*=}"; ONLY_SEEN=1 ;;
  --skip) [[ $# -ge 2 ]] || { echo "--skip requires module names, e.g. --skip tmux" >&2; exit 1; }; SKIP_RAW="$2"; SKIP_SEEN=1; shift ;;
  --skip=*) SKIP_RAW="${1#*=}"; SKIP_SEEN=1 ;;
  -h | --help)
    sed -n '2,19p' "$0"
    exit 0
    ;;
  *)
    echo "unknown arg: $1" >&2
    exit 1
    ;;
  esac; shift; done

# ── core/ subtree present? (inline: can't source a lib out of core/ before this) ─
# Validate the SPECIFIC paths we depend on (zsh modules + the two libs sourced
# next) so a missing/partial subtree fails HERE with a precise message, not later
# with a cryptic `source: No such file`.
for _req in core/zsh/loader.zsh core/lib/ux.sh core/lib/bootstrap-lib.sh; do
  if [[ ! -e "$DOTFILES/$_req" ]]; then
    echo "core/ subtree missing or incomplete (need $_req). One-time, run:" >&2
    echo "  git subtree add  --prefix=core <dotfiles-core remote> main --squash   # first time" >&2
    echo "  git subtree pull --prefix=core <dotfiles-core remote> main --squash   # to update" >&2
    exit 1
  fi
done
unset _req

# Shared bash UX palette + provisioning scaffold (vendored under core/lib).
# shellcheck source=core/lib/ux.sh
source "$DOTFILES/core/lib/ux.sh"
# shellcheck source=core/lib/bootstrap-lib.sh
source "$DOTFILES/core/lib/bootstrap-lib.sh"

# Apply any --only/--skip module selection now the validator (blib_select) exists;
# it aborts on a malformed selector or an unknown group.
if ((ONLY_SEEN)); then blib_select --only "$ONLY_RAW"; fi
if ((SKIP_SEEN)); then blib_select --skip "$SKIP_RAW"; fi

# ── privilege tool: Gentoo's norm is sudo; doas is also common. root => none. ──
# BLIB_SU hands the same escalator to bootstrap-lib (blib_set_login_shell).
if [[ "$(id -u)" -eq 0 ]]; then
  SU=""
elif command -v sudo >/dev/null 2>&1; then
  SU="sudo"
elif command -v doas >/dev/null 2>&1; then
  SU="doas"
else
  echo "Need root: run as root, or install app-admin/sudo." >&2
  exit 1
fi
export BLIB_SU="$SU"

# ── sanity: confirm we're on Gentoo ───────────────────────────────────────────
if ! grep -qiE '^ID=gentoo' /etc/os-release 2>/dev/null; then
  echo "This bootstrap targets Gentoo (expects ID=gentoo in /etc/os-release)." >&2
  exit 1
fi

IS_WSL=0
if blib_is_wsl; then IS_WSL=1; fi

# ── emerge options: quiet builds, skip already-installed (idempotent re-runs),
# and pull binary packages IF a binhost is configured (huge time-saver). ────────
EMERGE_OPTS=(--quiet-build=y --noreplace)
if [[ -s /etc/portage/binrepos.conf ]] || ls /etc/portage/binrepos.conf.d/*.conf >/dev/null 2>&1; then
  EMERGE_OPTS+=(--getbinpkg=y)
fi

# ── resilient emerge: a single masked/keyworded atom aborts the whole set, so
# bulk first, then one-by-one so the rest still go in. ──────────────────────────
emerge_install() {
  local -a atoms=("$@")
  # shellcheck disable=SC2086  # $SU is a single token (sudo/doas) or empty (root)
  if $SU emerge "${EMERGE_OPTS[@]}" "${atoms[@]}"; then return 0; fi
  blib_say "bulk emerge hit a snag (masked / keyworded atom?) — retrying one-by-one"
  local a
  for a in "${atoms[@]}"; do
    # shellcheck disable=SC2086  # see above
    $SU emerge "${EMERGE_OPTS[@]}" "$a" ||
      echo "   skipped: $a  (try 'emerge -p $a' — likely needs a keyword/USE; see gentoo/package.accept_keywords.example)"
  done
}

# ── GURU overlay: a handful of core-doctor tools aren't in the main tree but
# ARE in GURU. Enable GURU (once, best-effort) then emerge them tolerant of
# failure so a masked/absent atom never aborts the bootstrap. ────────────────────
guru_install() {
  local -a atoms=("$@")
  # Is GURU already known to Portage? (eselect repository list -i, or a repos.conf
  # entry / synced repo on disk). If not, enable + sync it — all best-effort.
  if ! eselect repository list -i 2>/dev/null | grep -qw guru &&
    [[ ! -d /var/db/repos/guru ]]; then
    blib_say "enabling the GURU overlay (for sd/glow/gum/xh/carapace/op)"
    # shellcheck disable=SC2086  # $SU: single token or empty (root)
    if $SU eselect repository enable guru >/dev/null 2>&1 &&
      $SU emaint sync -r guru >/dev/null 2>&1; then
      :
    else
      blib_warn "couldn't enable/sync GURU — skipping its tools (enable later: eselect repository enable guru && emaint sync -r guru)"
    fi
  fi
  # Only attempt the emerge if GURU is actually available now. Reuse the repo's
  # per-atom-tolerant emerge_install so one masked/keyworded GURU atom (e.g.
  # app-misc/gum) doesn't stop emerge early and skip the rest.
  if eselect repository list -i 2>/dev/null | grep -qw guru || [[ -d /var/db/repos/guru ]]; then
    blib_say "emerge GURU tools (best-effort): ${atoms[*]}"
    emerge_install "${atoms[@]}"
  fi
}

# ── go-install fallback: tools packaged nowhere. Uses the system go, else mise's
# go, else leaves a copy-paste hint. Always returns 0 (never aborts errexit). ────
# go install drops binaries in ~/go/bin, which is NOT on the shell PATH (the
# shell layer prefixes ~/.local/bin and ~/.cargo/bin). Point GOBIN at
# ~/.local/bin so the tool is actually found after bootstrap.
_dotfiles_go_install() { # <import-path@version> <binary-name>
  [ "$#" -ge 2 ] || return 0
  if command -v "$2" >/dev/null 2>&1; then return 0; fi
  local gobin="$HOME/.local/bin"
  mkdir -p "$gobin" 2>/dev/null || true
  if command -v go >/dev/null 2>&1; then
    GOBIN="$gobin" go install "$1" >/dev/null 2>&1 ||
      echo "   $2: go install failed — retry later: GOBIN=$gobin go install $1"
  elif command -v mise >/dev/null 2>&1; then
    GOBIN="$gobin" mise exec go@latest -- go install "$1" >/dev/null 2>&1 ||
      echo "   $2: go install failed — retry later: GOBIN=$gobin go install $1"
  else
    echo "   $2: needs Go — install later with: GOBIN=$gobin go install $1"
  fi
  return 0
}

provision() {
  if ((DO_SYNC)); then
    blib_say "emerge --sync (Portage tree — slow; re-run with --no-sync to skip)"
    # shellcheck disable=SC2086  # $SU: single token or empty (root)
    $SU emerge --sync --quiet || blib_say "sync failed/!configured — continuing with the current tree"
  fi

  if [[ " ${EMERGE_OPTS[*]} " == *" --getbinpkg=y "* ]]; then
    blib_say "binhost detected — pulling binary packages where available"
  else
    blib_say "no binhost configured — building from source (see README to enable --getbinpkg)"
  fi

  blib_say "emerge atoms (from install/packages.txt)"
  local -a atoms=()
  mapfile -t atoms < <(blib_read_pkgs "$DOTFILES/install/packages.txt")
  # Guard the empty case: an all-comment/blank packages.txt yields a zero-length
  # array. emerge_install wraps `emerge` in `if …; then` (errexit-exempt), so an
  # empty list wouldn't abort — but it WOULD run `emerge` with no atoms, trip the
  # "bulk emerge hit a snag" one-by-one fallback, and then log a misleading
  # "0 requested" success. Skip the emerge instead and carry on.
  if ((${#atoms[@]})); then
    emerge_install "${atoms[@]}"
    blib_ok "atoms requested: ${#atoms[@]}"
  else
    blib_warn "install/packages.txt lists no atoms — skipping emerge"
  fi

  # mise — not in the main Gentoo tree; official installer (glibc build is fine).
  if ! command -v mise >/dev/null && [[ ! -x "$HOME/.local/bin/mise" ]]; then
    blib_say "mise (official installer)"
    curl -fsSL https://mise.run | sh >/dev/null 2>&1 || true
  fi
  # tree-sitter-cli — not packaged; build via cargo (dev-lang/rust-bin provides it).
  if ! command -v tree-sitter >/dev/null && command -v cargo >/dev/null; then
    blib_say "tree-sitter-cli (cargo build)"
    cargo install --locked tree-sitter-cli >/dev/null 2>&1 ||
      echo "   tree-sitter-cli build failed; retry later: cargo install tree-sitter-cli"
  fi
  # NOTE: starship / atuin are emerged from packages.txt on Gentoo (they ARE in
  # the main tree), so unlike the other repos there's no curl installer here. yazi
  # is NOT in the main tree (GURU-only) — it's emerged in the guru_install block.

  # ── core-doctor extras from the GURU overlay (best-effort; never aborts) ──────
  # tealdeer / yazi / lazygit / direnv are also GURU-only (not in the main tree),
  # so they belong here — the packages.txt emerge above runs before GURU is enabled,
  # so there they'd just fail with a `skipped:` line and never get retried.
  guru_install \
    sys-apps/sd \
    app-misc/glow \
    app-misc/gum \
    net-misc/xh \
    app-shells/carapace \
    app-misc/1password-cli \
    app-misc/tealdeer \
    app-misc/yazi \
    dev-vcs/lazygit \
    app-shells/direnv

  # ── go-install tools (packaged nowhere): gron, sesh ──────────────────────────
  _dotfiles_go_install github.com/tomnomnom/gron@latest gron
  _dotfiles_go_install github.com/joshmedeski/sesh/v2@latest sesh

  # ── WSL: install /etc/wsl.conf. No systemd=true — Gentoo defaults to OpenRC. ──
  if ((IS_WSL)); then
    blib_say "installing /etc/wsl.conf (default user + interop; OpenRC default)"
    local user
    user="$(id -un)"
    # shellcheck disable=SC2086  # $SU: single token or empty (root)
    sed "s/__WSL_USER__/$user/" "$DOTFILES/wsl/wsl.conf" | $SU tee /etc/wsl.conf >/dev/null
    blib_ok "wsl.conf written — run 'wsl.exe --shutdown' from Windows, then reopen"
  fi
}

wire_links() {
  # The shared symlink surface + the Gentoo OS overlays + the managed .zshrc
  # loader + the default-login-shell switch all live in core/lib/bootstrap-lib.sh.
  blib_link_core "$DOTFILES" "$CONFIG"
  blib_link_os_layer "$DOTFILES" "$CONFIG" gentoo
  # shellcheck disable=SC2119  # no args is intentional — writes the default module set
  blib_write_zshrc_loader
  blib_set_login_shell
  blib_ok "symlinks wired$(blib_selected_note)"
}

((LINKS_ONLY)) || provision
wire_links
blib_ok "Gentoo bootstrap complete — open a new shell or: exec zsh"
