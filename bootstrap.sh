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
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
LINKS_ONLY=0
DO_SYNC=1

for a in "$@"; do case "$a" in
  --links-only) LINKS_ONLY=1 ;;
  --no-sync) DO_SYNC=0 ;;
  -h | --help)
    sed -n '2,13p' "$0"
    exit 0
    ;;
  *)
    echo "unknown arg: $a" >&2
    exit 1
    ;;
  esac; done

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
  emerge_install "${atoms[@]}"
  blib_ok "atoms requested: ${#atoms[@]}"

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
  # NOTE: starship / atuin / yazi are emerged from packages.txt on Gentoo (they
  # ARE in the main tree), so unlike the other repos there's no curl installer here.

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
  blib_ok "symlinks wired"
}

((LINKS_ONLY)) || provision
wire_links
blib_ok "Gentoo bootstrap complete — open a new shell or: exec zsh"
