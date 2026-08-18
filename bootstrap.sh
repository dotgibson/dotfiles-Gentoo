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
PORTAGE_CONFIG=1
EXTRAS=1
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
  ./bootstrap.sh --no-portage-config  # do NOT touch /etc/portage
  ./bootstrap.sh --no-extras     # skip the opt-in source builds (see below)
  ./bootstrap.sh --only zsh,nvim # link ONLY these Core module groups
  ./bootstrap.sh --skip tmux     # link everything EXCEPT these groups

Module groups (for --only/--skip): zsh nvim tmux git prompt tools
They affect the wiring steps only, never package provisioning; combine with
--links-only to re-wire a subset of configs without touching Portage.

Gentoo notes:
  • emerge COMPILES. Enable the binhost (auto-detected here) and keep
    dev-lang/rust-bin rather than dev-lang/rust — see the README.
  • Unless --no-portage-config is given, two namespaced files are installed under
    /etc/portage: package.accept_keywords/90-dotfiles-Gentoo and
    package.license/90-dotfiles-Gentoo. Without them a stable profile cannot
    install ~a quarter of this stack at all. Preview with --dry-run; the sources
    are gentoo/package.accept_keywords and gentoo/package.license.
  • MAKEOPTS is set for the run when your make.conf does not set it — Portage
    otherwise compiles single-threaded, which on a source-based distro is the
    difference between minutes and hours.
  • Five tools are packaged nowhere on Gentoo and are built with cargo: ouch,
    ast-grep, jnv, jj, watchexec. Nothing in Core wires them by default (every
    one is HAVE_*-gated), so --no-extras skips them for a faster first run —
    at the cost of a ✗ next to each in `core doctor`. The tools Core DOES wire
    (tree-sitter, viddy, gron, sesh, shfmt) are always installed.
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
  --no-portage-config) PORTAGE_CONFIG=0 ;;
  --no-extras) EXTRAS=0 ;;
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
# Read ID out of os-release, tolerating the QUOTING the format permits. Real
# Gentoo ships the value quoted —
#
#   $ grep ^ID= /etc/os-release
#   ID='gentoo'
#
# — so the previous `grep -qiE '^ID=gentoo'` matched nothing, and this script
# refused to run on the one OS it targets.
#
# os-release(5) says the file may be sourced, and `. /etc/os-release` is the
# conventional read. It is deliberately NOT used here: sourcing executes the file,
# which is an execution surface this needs nothing from — one scalar field, whose
# value is a lowercase identifier. Stripping one optional layer of matching quotes
# is the whole job, so do that and keep the parser inert.
#
# CI never caught the original bug because bootstrap.yml's prep step appends an
# UNQUOTED `ID=gentoo` to the container's os-release, manufacturing the one form
# the old grep accepted — the gate was green while the script could not start on a
# real box. Fixing that fixture is a one-line prep change in a follow-up PR (the
# push token here has no `workflow` scope); until it lands, CI still exercises only
# the bare spelling, and THIS box is the coverage for the quoted one.
_os_id=""
if [[ -r /etc/os-release ]]; then
  _os_id="$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | head -n1)"
  _os_id="${_os_id%\"}"; _os_id="${_os_id#\"}"   # ID="gentoo"
  _os_id="${_os_id%\'}"; _os_id="${_os_id#\'}"   # ID='gentoo'
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

# ── cargo-install fallback: Rust CLIs packaged nowhere on Gentoo ───────────────
# Same shape as _dotfiles_go_install below: guarded on the binary already existing
# (which now WORKS, because blib_user_bindirs_on_path put ~/.cargo/bin on PATH —
# without it every one of these rebuilt from source on every run), never aborts,
# and records a failure rather than printing one into the scroll.
#
# The crate name is NOT always the binary name and getting it wrong is silent:
# `jj-cli` provides `jj` (the `jujutsu` crate is an abandoned stub that just
# redirects), and `watchexec-cli` provides `watchexec` (plain `watchexec` is the
# library — installing it gives you no binary at all). Both are documented in
# core/PORTING-MATRIX.md, footnotes 8 and 25.
_dotfiles_cargo_install() { # <crate> <binary-name>
  [ "$#" -ge 2 ] || return 0
  if command -v "$2" >/dev/null 2>&1; then return 0; fi
  if ! command -v cargo >/dev/null 2>&1; then
    blib_note_fail "$2: needs cargo (dev-lang/rust-bin, in packages.txt) — install later: cargo install --locked $1"
    return 0
  fi
  blib_say "$2 (cargo build — crate: $1)"
  cargo install --locked "$1" >/dev/null 2>&1 ||
    blib_note_fail "$2: cargo build failed — retry later: cargo install --locked $1"
  return 0
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

# ── /etc/portage config: keywords + licences ──────────────────────────────────
# Gentoo's stable profile does not carry a usable keyword for every tool in this
# stack — `app-shells/zoxide` and `sys-fs/duf` have NO stable-keyworded ebuild in
# ::gentoo at all, and GURU is testing-keyworded by policy. Shipping the fix as a
# commented-out .example (as this repo did) meant a fresh box finished "complete"
# having silently skipped roughly a quarter of the stack.
#
# So: install it. Rules that keep this honest rather than invasive —
#   • ONE namespaced file per directory (90-dotfiles-Gentoo), never a shared file,
#     so uninstalling is `rm` and nothing we wrote can collide with a hand-written
#     entry or with a file another package owns;
#   • idempotent — byte-identical content is a no-op, a differing file is backed
#     up to .pre-dotfiles.<epoch> before being replaced;
#   • opt-out with --no-portage-config, previewable with --dry-run;
#   • per-atom lines only. No `*/* ~arch`.
#
# __ARCH__ is rendered from `portageq envvar ARCH` so this is correct on arm64 or
# any other arch, not just amd64.
_portage_conf_install() { # <src> <portage-subdir>
  local src="$1" dir="/etc/portage/$2" dst="/etc/portage/$2/90-dotfiles-Gentoo"
  local arch rendered current
  [[ -r "$src" ]] || {
    blib_note_fail "portage config: $src is missing — skipped"
    return 0
  }
  # portageq is authoritative: ARCH is Portage's KEYWORD name, which is NOT the
  # kernel's machine name. `uname -m` says x86_64 where Portage says amd64, and
  # aarch64 where Portage says arm64 — so the old fallback would have rendered
  # `~x86_64`, a keyword that matches nothing. The file would install cleanly and
  # every atom would stay masked: a silent no-op that looks like success.
  #
  # Hence: map the handful of known kernel names, and REFUSE to write anything for
  # an unrecognised one. A wrong keyword file is worse than none, because none at
  # least fails loudly at the emerge.
  arch="$(portageq envvar ARCH 2>/dev/null || true)"
  if [[ -z "$arch" ]]; then
    case "$(uname -m 2>/dev/null || true)" in
      x86_64 | amd64) arch=amd64 ;;
      aarch64 | arm64) arch=arm64 ;;
      armv7l | armv6l) arch=arm ;;
      i?86) arch=x86 ;;
      ppc64le | ppc64) arch=ppc64 ;;
      riscv64) arch=riscv ;;
      *)
        blib_note_fail "portage config: could not determine Portage's ARCH (portageq unavailable, and '$(uname -m 2>/dev/null)' is not a name I map) — skipped ${src##*/}; set it by hand in $dst"
        return 0
        ;;
    esac
    blib_warn "portageq unavailable — inferred ARCH=$arch from uname; verify with 'portageq envvar ARCH'"
  fi
  rendered="$(<"$src")"
  rendered="${rendered//__ARCH__/$arch}"

  # A single REGULAR FILE at /etc/portage/package.accept_keywords is a valid (and
  # older) layout — we cannot drop a file inside it. Say so precisely instead of
  # failing with a confusing mkdir error.
  if [[ -f "$dir" && ! -d "$dir" ]]; then
    blib_note_fail "portage config: $dir is a regular file, not a directory — append the contents of $src to it by hand (rendering __ARCH__ as $arch), or convert it: mv $dir $dir.tmp && mkdir $dir && mv $dir.tmp $dir/00-local, then re-run"
    return 0
  fi

  current=""
  [[ -r "$dst" ]] && current="$(<"$dst")"
  if [[ -e "$dst" && "$rendered" == "$current" ]]; then
    blib_say "portage config: $dst already current"
    return 0
  fi
  if ((DRY)); then
    if [[ -e "$dst" ]]; then
      blib_say "would back up + rewrite $dst (from ${src##*/}, ARCH=$arch)"
    else
      blib_say "would install $dst (from ${src##*/}, ARCH=$arch)"
    fi
    return 0
  fi
  blib_priv mkdir -p "$dir" || {
    blib_note_fail "portage config: could not create $dir — skipped"
    return 0
  }
  if [[ -e "$dst" ]]; then
    # RETURN on a failed backup: writing anyway would destroy the content the
    # backup exists to preserve, while logging "leaving it untouched".
    blib_priv cp -p "$dst" "$dst.pre-dotfiles.$(date +%s)" || {
      blib_note_fail "portage config: could not back up $dst — leaving it untouched (fix the backup, then re-run)"
      return 0
    }
  fi
  printf '%s\n' "$rendered" | blib_priv tee "$dst" >/dev/null || {
    blib_note_fail "portage config: could not write $dst"
    return 0
  }
  blib_ok "portage config: $dst"
}

install_portage_config() {
  ((PORTAGE_CONFIG)) || {
    blib_say "--no-portage-config: leaving /etc/portage alone (keyword/licence-masked atoms will be skipped)"
    return 0
  }
  _portage_conf_install "$DOTFILES/gentoo/package.accept_keywords" package.accept_keywords
  _portage_conf_install "$DOTFILES/gentoo/package.license" package.license
}

# ── build parallelism ─────────────────────────────────────────────────────────
# A stage3's make.conf ships with NO MAKEOPTS, so Portage compiles single-threaded.
# On a source-based distro that is the single largest avoidable cost of a bootstrap
# — measured on this box: 32 cores sitting idle behind `-j1`.
#
# Set it for THIS RUN only (exported into the environment Portage reads), never by
# editing make.conf: the permanent value is the operator's call, and the README
# says so. If make.conf or the environment already sets it, that wins untouched.
#
# The job count is min(nproc, RAM_GB / 2) — the standard Gentoo guidance, because
# parallel compiler processes are bounded by memory long before they are bounded by
# cores (a 4-core/2 GB VPS that runs -j4 will OOM mid-build, and the failure lands
# somewhere far from its cause).
_tune_build_parallelism() {
  local cur cores memkb memjobs jobs
  cur="${MAKEOPTS:-}"
  [[ -z "$cur" ]] && cur="$(portageq envvar MAKEOPTS 2>/dev/null || true)"
  if [[ -n "$cur" ]]; then
    blib_say "MAKEOPTS already set ($cur) — left alone"
    return 0
  fi
  cores="$(nproc 2>/dev/null || echo 1)"
  memkb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
  memjobs=$((memkb / 1024 / 1024 / 2)) # GB / 2
  ((memjobs < 1)) && memjobs=1
  jobs="$cores"
  ((memjobs < jobs)) && jobs="$memjobs"
  export MAKEOPTS="-j$jobs"
  blib_say "MAKEOPTS unset in make.conf — using -j$jobs for this run (${cores} cores, $((memkb / 1024 / 1024)) GB RAM). Make it permanent in /etc/portage/make.conf."
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
    # RETURN on a failed backup rather than carrying on. Writing the new file
    # anyway would destroy the very content the backup exists to preserve, while
    # logging "leaving it untouched" — a message that would then be a lie.
    blib_priv cp -p /etc/wsl.conf "/etc/wsl.conf.pre-dotfiles.$(date +%s)" || {
      blib_note_fail "could not back up /etc/wsl.conf — leaving it untouched (fix the backup, then re-run)"
      return 0
    }
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
    install_portage_config
    _tune_build_parallelism
    # ${DO_SYNC:+…} would be WRONG here: :+ tests non-EMPTY, and "0" is non-empty,
    # so --no-sync still printed "would emerge --sync". Test the value.
    ((DO_SYNC)) && blib_say "would emerge --sync (Portage tree)"
    ((DO_SYNC)) || blib_say "--no-sync: would skip emerge --sync"
    blib_say "would emerge ${#atoms[@]} atoms from install/packages.txt:"
    # --dry-run promises the full plan, so name them. A count alone cannot tell you
    # that the atom you just added is being read the way you meant it.
    ((${#atoms[@]})) && printf '     %s\n' "${atoms[@]}"
    blib_say "would enable the GURU overlay and emerge its tools (best-effort)"
    blib_say "would install mise / tree-sitter-cli / viddy where missing"
    blib_say "would go-install: gron, sesh, shfmt"
    if ((EXTRAS)); then
      blib_say "would cargo-build the opt-in set: ouch, ast-grep, jnv, jj, watchexec"
    else
      blib_say "--no-extras: would skip ouch / ast-grep / jnv / jj / watchexec"
    fi
    ((IS_WSL)) && install_wsl_conf
    return 0
  fi

  # Keywords + licences BEFORE the first emerge: they are what makes the emerge
  # below able to install the atoms at all.
  install_portage_config
  _tune_build_parallelism

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
  # ── cargo builds Core actively WIRES (not optional) ──────────────────────────
  # tree-sitter-cli backs nvim-treesitter; viddy backs the watch->viddy alias.
  _dotfiles_cargo_install tree-sitter-cli tree-sitter
  _dotfiles_cargo_install viddy viddy
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
    app-shells/direnv \
    net-analyzer/gping

  # ── go-install tools (packaged nowhere) ──────────────────────────────────────
  # gron and sesh are wired by Core (sesh is the Ctrl-G session picker); shfmt backs
  # nvim's conform formatter and is the one tool in this stack that is absent from
  # BOTH ::gentoo and GURU (PORTING-MATRIX footnote 7 — there is no dev-go/shfmt
  # atom, and the overlays that do carry it call it dev-util/shfmt).
  _dotfiles_go_install github.com/tomnomnom/gron@latest gron
  _dotfiles_go_install github.com/joshmedeski/sesh/v2@latest sesh
  _dotfiles_go_install mvdan.cc/sh/v3/cmd/shfmt@latest shfmt

  # ── opt-in source builds (--no-extras skips these) ───────────────────────────
  # Packaged nowhere on Gentoo. Every one is HAVE_*-gated in Core, so skipping them
  # costs nothing but a ✗ in `core doctor` — which is precisely why they were never
  # installed and the doctor was never clean. jj is additive and never replaces git.
  if ((EXTRAS)); then
    _dotfiles_cargo_install ouch ouch
    _dotfiles_cargo_install ast-grep ast-grep
    _dotfiles_cargo_install jnv jnv
    _dotfiles_cargo_install jj-cli jj
    _dotfiles_cargo_install watchexec-cli watchexec
  else
    blib_say "--no-extras: skipping ouch / ast-grep / jnv / jj / watchexec"
  fi

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
