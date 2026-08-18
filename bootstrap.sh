#!/usr/bin/env bash
# dotfiles-Gentoo/bootstrap.sh
# ──────────────────────────────────────────────────────────────────────────────
# Provision a Gentoo box and wire dotfiles. Idempotent. OS-NATIVE layer; Core
# (zsh/tmux/nvim/git) is vendored under core/ and symlinked via core/lib/bootstrap-lib.sh.
# Gentoo is source-based: emerge COMPILES, so a full run can take a while. Two
# mitigations are wired in — the official binhost (--getbinpkg, auto-detected)
# and dev-lang/rust-bin (in packages.txt) instead of compiling Rust from source.
#
# The SHARED half of this script lives in core/lib/bootstrap-lib.sh and is called,
# not re-implemented: privilege resolution (blib_resolve_su), the sudo-timestamp
# keepalive, the user-bindir PATH fix, deferred-failure accounting, the symlink
# surface, and the core/ pre-commit guard. Anything hand-rolled here that Core
# already solves is drift — see that file's header for the contract.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
LINKS_ONLY=0
DO_SYNC=1
STRICT=0
DRY=0
# --only/--skip are validated by the shared lib (blib_select), which is sourced
# AFTER this loop — so capture the raw values now and apply them below.
ONLY_RAW="" SKIP_RAW="" ONLY_SEEN=0 SKIP_SEEN=0

# usage — a heredoc, not `sed -n '2,19p' "$0"`. The line-range form silently
# truncated (or printed half a comment block) the moment anyone edited the header,
# which is exactly the kind of coupling a header comment invites.
usage() {
  cat <<'USAGE'
Provision a Gentoo box and wire the dotfiles. Idempotent — safe to re-run.

Usage:
  ./bootstrap.sh                 # sync + emerge atoms + extras + symlinks
  ./bootstrap.sh --no-sync       # skip the (slow) `emerge --sync`
  ./bootstrap.sh --links-only    # just (re)create symlinks (needs no privileges)
  ./bootstrap.sh --dry-run       # print the full plan, change nothing
  ./bootstrap.sh --strict        # exit non-zero if any best-effort step failed
  ./bootstrap.sh --only zsh,nvim # link ONLY these Core module groups
  ./bootstrap.sh --skip tmux     # link everything EXCEPT these groups

Module groups (for --only/--skip): zsh nvim tmux git prompt tools
They affect the wiring steps only, never package provisioning; combine with
--links-only to re-wire a subset of configs without touching Portage.

Gentoo notes:
  • emerge COMPILES. Enable the binhost (auto-detected here) and keep
    dev-lang/rust-bin rather than dev-lang/rust — see the README.
  • A keyword/USE-masked atom is skipped, reported, and never fatal; the run
    ends with a list of everything that did not complete. --strict turns that
    list into a non-zero exit (use it in CI).
USAGE
}

while [[ $# -gt 0 ]]; do case "$1" in
  --links-only) LINKS_ONLY=1 ;;
  --no-sync) DO_SYNC=0 ;;
  --dry-run) DRY=1 ;;
  --strict) STRICT=1 ;;
  --only) [[ $# -ge 2 ]] || {
    echo "--only requires module names, e.g. --only zsh,nvim" >&2
    exit 1
  }; ONLY_RAW="$2"; ONLY_SEEN=1; shift ;;
  --only=*) ONLY_RAW="${1#*=}"; ONLY_SEEN=1 ;;
  --skip) [[ $# -ge 2 ]] || {
    echo "--skip requires module names, e.g. --skip tmux" >&2
    exit 1
  }; SKIP_RAW="$2"; SKIP_SEEN=1; shift ;;
  --skip=*) SKIP_RAW="${1#*=}"; SKIP_SEEN=1 ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "unknown arg: $1" >&2
    usage >&2
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
# BLIB_DRY is the lib's own dry-run switch: every mutating helper (blib_link,
# blib_seed, blib_write_zshrc_loader, blib_set_login_shell, …) then PRINTS what it
# would do and changes nothing. Export before sourcing so it is in effect from the
# first helper call.
((DRY)) && export BLIB_DRY=1
# shellcheck source=core/lib/ux.sh
source "$DOTFILES/core/lib/ux.sh"
# shellcheck source=core/lib/bootstrap-lib.sh
source "$DOTFILES/core/lib/bootstrap-lib.sh"

# Apply any --only/--skip module selection now the validator (blib_select) exists;
# it aborts on a malformed selector or an unknown group.
if ((ONLY_SEEN)); then blib_select --only "$ONLY_RAW"; fi
if ((SKIP_SEEN)); then blib_select --skip "$SKIP_RAW"; fi

# ── privilege tool ────────────────────────────────────────────────────────────
# blib_resolve_su, NOT a hand-rolled probe. It pins the ABSOLUTE path of sudo/doas
# (so a later PATH change or an exported `sudo()` function cannot redirect a
# privileged call), and it decides "are we root" from $EUID rather than from
# `[[ "$(id -u)" -eq 0 ]]` — an ARITHMETIC comparison in which an empty `id` output
# evaluates as 0, i.e. a box with no `id` on PATH concludes it is root and runs the
# whole provision unescalated. Both were live here before.
#
# --require only when we are actually going to install something: wiring symlinks
# needs no privileges at all, so a links-only or dry run on an unprivileged box
# must still work.
if ((LINKS_ONLY)) || ((DRY)); then
  blib_resolve_su || true
else
  blib_resolve_su --require || exit 1
fi

# ── PATH: the per-user bindirs language installers write into ─────────────────
# cargo writes $CARGO_HOME/bin and go writes $GOBIN; neither is on a fresh box's
# bash PATH (they reach PATH via the OS zsh layer — i.e. only inside a Core shell
# that does not exist yet). Without this every `command -v <tool>` guard below
# answers "missing" for a tool that IS installed, and each re-run recompiles
# tree-sitter-cli and viddy from source: minutes of work, silently discarded.
blib_user_bindirs_on_path

# ── sanity: confirm we're on Gentoo ───────────────────────────────────────────
# SOURCE os-release; do not grep it. Real Gentoo ships the value QUOTED —
#
#   $ grep ^ID= /etc/os-release
#   ID='gentoo'
#
# — so the previous `grep -qiE '^ID=gentoo'` matched nothing and this script
# refused to run on the one OS it targets. os-release(5) explicitly permits
# shell-style quoting, which is why the format's contract is "source it", and
# sourcing also gets the unquoted spelling for free.
#
# CI never caught it because bootstrap.yml's prep step appends an UNQUOTED
# `ID=gentoo` to the container's os-release, manufacturing the one form the old
# grep accepted. That prep now writes the quoted form a real box has.
_os_id=""
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091  # runtime OS metadata, not a repo file
  _os_id="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")" || _os_id=""
fi
_os_id="$(printf '%s' "$_os_id" | tr '[:upper:]' '[:lower:]')"
if [[ "$_os_id" != gentoo ]]; then
  echo "This bootstrap targets Gentoo (expects ID=gentoo in /etc/os-release; found '${_os_id:-<none>}')." >&2
  exit 1
fi
unset _os_id

IS_WSL=0
if blib_is_wsl; then IS_WSL=1; fi

# ── keep the sudo timestamp warm for the whole run ────────────────────────────
# Gentoo is the worst case for this: a single `emerge` can run for HOURS, so sudo's
# 5-minute timestamp is long expired by the time the GURU block runs — and those
# calls redirect stderr, which is where sudo writes its prompt. The result is a
# process waiting on a TTY read with nothing on screen: no output, no progress,
# indistinguishable from a hang. Prime it once up front (visibly, at the start) and
# refresh it in the background until we exit.
if ((LINKS_ONLY == 0)) && ((DRY == 0)); then
  trap 'blib_sudo_keepalive_stop' EXIT
  blib_sudo_keepalive_start || {
    blib_warn "sudo authentication failed — aborting before provisioning anything"
    exit 1
  }
fi

# ── emerge options: quiet builds, skip already-installed (idempotent re-runs),
# and pull binary packages IF a binhost is configured (huge time-saver). ────────
EMERGE_OPTS=(--quiet-build=y --noreplace)
if [[ -s /etc/portage/binrepos.conf ]] || ls /etc/portage/binrepos.conf.d/*.conf >/dev/null 2>&1; then
  EMERGE_OPTS+=(--getbinpkg=y)
fi

# ── resilient emerge: a single masked/keyworded atom aborts the whole set, so
# bulk first, then one-by-one so the rest still go in. ──────────────────────────
# A skipped atom is recorded with blib_note_fail (stderr + the end-of-run tally),
# not echoed to stdout: a `skipped:` line scrolling past in the middle of an
# hour-long emerge is not a report, and the run used to end "complete" / exit 0
# with no trace of it.
emerge_install() {
  local -a atoms=("$@")
  if blib_priv emerge "${EMERGE_OPTS[@]}" "${atoms[@]}"; then return 0; fi
  blib_say "bulk emerge hit a snag (masked / keyworded atom?) — retrying one-by-one"
  local a
  for a in "${atoms[@]}"; do
    blib_priv emerge "${EMERGE_OPTS[@]}" "$a" ||
      blib_note_fail "emerge skipped: $a (try 'emerge -p $a' — likely needs a keyword/USE; see gentoo/package.accept_keywords.example)"
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
    if blib_priv eselect repository enable guru >/dev/null 2>&1 &&
      blib_priv emaint sync -r guru >/dev/null 2>&1; then
      :
    else
      blib_note_fail "could not enable/sync the GURU overlay — its tools are skipped (needs app-eselect/eselect-repository; enable later with: eselect repository enable guru && emaint sync -r guru)"
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
      blib_note_fail "$2: go install failed — retry later: GOBIN=$gobin go install $1"
  elif command -v mise >/dev/null 2>&1; then
    GOBIN="$gobin" mise exec go@latest -- go install "$1" >/dev/null 2>&1 ||
      blib_note_fail "$2: go install failed — retry later: GOBIN=$gobin go install $1"
  else
    blib_note_fail "$2: needs Go — install later with: GOBIN=$gobin go install $1"
  fi
  return 0
}

# ── /etc/wsl.conf ─────────────────────────────────────────────────────────────
# Rendered in bash (not sed): the username is substituted with ${var//…}, so a name
# containing a sed metacharacter — `/` ends the s/// expression, `&` expands to the
# whole match — cannot corrupt the file.
#
# Idempotent and non-destructive, which the previous `sed … | tee` was neither: it
# rewrote /etc/wsl.conf on EVERY run with no backup, so a hand-added `[boot]
# systemd=true` (which this repo's own wsl/wsl.conf comment invites you to add) was
# silently destroyed by the next bootstrap.
install_wsl_conf() {
  local user rendered current
  user="$(id -un)"
  rendered="$(<"$DOTFILES/wsl/wsl.conf")"
  rendered="${rendered//__WSL_USER__/$user}"
  current=""
  [[ -r /etc/wsl.conf ]] && current="$(</etc/wsl.conf)"
  if [[ -e /etc/wsl.conf && "$rendered" == "$current" ]]; then
    blib_say "/etc/wsl.conf already current — left alone"
    return 0
  fi
  if ((DRY)); then
    if [[ -e /etc/wsl.conf ]]; then
      blib_say "would back up + rewrite /etc/wsl.conf (default user + interop)"
    else
      blib_say "would install /etc/wsl.conf (default user + interop; OpenRC default)"
    fi
    return 0
  fi
  if [[ -e /etc/wsl.conf ]]; then
    blib_say "backing up the existing /etc/wsl.conf before rewriting it"
    blib_priv cp -p /etc/wsl.conf "/etc/wsl.conf.pre-dotfiles.$(date +%s)" ||
      blib_note_fail "could not back up /etc/wsl.conf — leaving it untouched"
  fi
  blib_say "installing /etc/wsl.conf (default user + interop; OpenRC default)"
  printf '%s\n' "$rendered" | blib_priv tee /etc/wsl.conf >/dev/null
  blib_ok "wsl.conf written — run 'wsl.exe --shutdown' from Windows, then reopen"
}

provision() {
  # A missing package list is a BROKEN CHECKOUT, not "no atoms to install".
  # blib_read_pkgs reads it with `<"$1"`, which under errexit-exempt command
  # substitution yields an empty list and a cheerful run (dotfiles-core#460), so
  # check it here where the answer is unambiguous.
  local pkglist="$DOTFILES/install/packages.txt"
  [[ -r "$pkglist" ]] || {
    blib_warn "install/packages.txt is missing or unreadable ($pkglist) — this is a broken checkout, not an empty package set"
    exit 1
  }

  local -a atoms=()
  mapfile -t atoms < <(blib_read_pkgs "$pkglist")

  if ((DRY)); then
    blib_say "would ${DO_SYNC:+emerge --sync, then }emerge ${#atoms[@]} atoms from install/packages.txt"
    blib_say "would enable the GURU overlay and emerge its tools (best-effort)"
    blib_say "would install mise / tree-sitter-cli / viddy where missing"
    blib_say "would go-install: gron, sesh"
    ((IS_WSL)) && install_wsl_conf
    return 0
  fi

  if ((DO_SYNC)); then
    blib_say "emerge --sync (Portage tree — slow; re-run with --no-sync to skip)"
    blib_priv emerge --sync --quiet || blib_note_fail "emerge --sync failed or is not configured — continued with the current tree"
  fi

  if [[ " ${EMERGE_OPTS[*]} " == *" --getbinpkg=y "* ]]; then
    blib_say "binhost detected — pulling binary packages where available"
  else
    blib_say "no binhost configured — building from source (see README to enable --getbinpkg)"
  fi

  blib_say "emerge atoms (from install/packages.txt)"
  # Guard the empty case: an all-comment/blank packages.txt yields a zero-length
  # array, and running `emerge` with no atoms would trip the one-by-one fallback and
  # then log a misleading "0 requested" success.
  if ((${#atoms[@]})); then
    emerge_install "${atoms[@]}"
    blib_ok "atoms requested: ${#atoms[@]}"
  else
    blib_note_fail "install/packages.txt lists no atoms — nothing was emerged"
  fi

  # mise — not in the main Gentoo tree; official installer (glibc build is fine).
  if ! command -v mise >/dev/null && [[ ! -x "$HOME/.local/bin/mise" ]]; then
    blib_say "mise (official installer)"
    curl -fsSL https://mise.run | sh >/dev/null 2>&1 ||
      blib_note_fail "mise: installer failed — retry later: curl -fsSL https://mise.run | sh"
  fi
  # tree-sitter-cli — not packaged; build via cargo (dev-lang/rust-bin provides it).
  if ! command -v tree-sitter >/dev/null && command -v cargo >/dev/null; then
    blib_say "tree-sitter-cli (cargo build)"
    cargo install --locked tree-sitter-cli >/dev/null 2>&1 ||
      blib_note_fail "tree-sitter-cli: cargo build failed — retry later: cargo install --locked tree-sitter-cli"
  fi
  # viddy (watch replacement; Core aliases watch->viddy, HAVE_VIDDY-guarded) is a Rust
  # CLI, packaged nowhere on Gentoo — build via cargo.
  if ! command -v viddy >/dev/null && command -v cargo >/dev/null; then
    blib_say "viddy (cargo build — watch replacement)"
    cargo install --locked viddy >/dev/null 2>&1 ||
      blib_note_fail "viddy: cargo build failed — retry later: cargo install --locked viddy"
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
  ((IS_WSL)) && install_wsl_conf
  return 0
}

wire_links() {
  # The shared symlink surface + the Gentoo OS overlays + the managed .zshrc
  # loader + the default-login-shell switch all live in core/lib/bootstrap-lib.sh.
  blib_link_core "$DOTFILES" "$CONFIG"
  blib_link_os_layer "$DOTFILES" "$CONFIG" gentoo
  # shellcheck disable=SC2119  # no args is intentional — writes the default module set
  blib_write_zshrc_loader
  blib_set_login_shell
  # The local half of the "never hand-edit core/" rule (VENDORING.md). Only
  # sync-core.sh installed this before — i.e. only on the maintainer's machine
  # during a fan-out — so every other clone had no guard at all. It is idempotent
  # and never clobbers an unrelated pre-commit hook.
  # Guarded on DRY by hand: blib_install_core_guard does not itself honour
  # BLIB_DRY, and a dry run must not write into .git/hooks.
  if ((DRY)); then
    blib_say "would install the core/ pre-commit guard into .git/hooks"
  else
    blib_install_core_guard "$DOTFILES"
  fi
  blib_ok "symlinks wired$(blib_selected_note)"
}

((LINKS_ONLY)) || provision
wire_links
blib_wire_summary

# ── the honest ending ─────────────────────────────────────────────────────────
# Every best-effort step that failed was recorded with blib_note_fail; print them
# together here. Without this the script ended `blib_ok "complete"` / exit 0 even
# when nothing optional had installed — a box that got none of its tooling was
# indistinguishable from a good one, to the operator and to CI alike. (It also
# dropped failures the shared lib itself recorded, e.g. a failed tpm clone.)
_rc=0
blib_failures_report || _rc=1
if ((DRY)); then
  blib_ok "dry run complete — nothing was changed"
  exit 0
fi
if ((_rc)); then
  if ((STRICT)); then
    blib_warn "Gentoo bootstrap finished with failures (--strict) — see the list above"
    exit 1
  fi
  blib_warn "Gentoo bootstrap finished, but the steps above did not complete — re-run with --strict to make this a non-zero exit"
  exit 0
fi
blib_ok "Gentoo bootstrap complete — open a new shell or: exec zsh"
