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
USER_MODE=0
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
  ./bootstrap.sh --user          # install everything into $HOME, no privileges
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
  • --user is the no-root path: no emerge, no /etc/portage, nothing outside
    $HOME. The stack comes from mise (prebuilt binaries), cargo and go instead,
    and zsh is built from source into ~/.local. It is selected automatically
    when there is no way to escalate, because the alternative — aborting — leaves
    an unusable box on an account that simply cannot install packages.
  • Five tools are optional extras, skipped by --no-extras, and they arrive by
    three different routes. THREE are in neither tree and are built with cargo
    (ast-grep, jnv, watchexec) — GURU does carry watchexec, and cargo is chosen
    over it for upstream-latest. ouch is app-arch/ouch from GURU: its cargo build
    cannot succeed on a libstdc++ box, so upstream-latest was never on offer there
    (see guru_extras_install). jj is dev-vcs/jj from ::gentoo (~arch — see
    gentoo/package.accept_keywords). Nothing in Core wires them by default
    (every one is HAVE_*-gated), so --no-extras is a faster first run — at the
    cost of a ✗ next to each in `core doctor`. The tools Core DOES wire
    (tree-sitter, viddy, gron, sesh, shfmt) are always installed — tree-sitter as
    an emerged atom now (so --getbinpkg can supply it), the rest via cargo/go.
  • A keyword/USE-masked atom is skipped, reported, and never fatal; the run
    ends with a list of everything that did not complete. --strict turns that
    list into a non-zero exit.

--strict IS OFF BY DEFAULT, AND THAT IS A DECISION, not an oversight (issue #133).
The end-of-run ledger mixes two unlike things: a genuine provisioning gap (an atom
that will never install here) and an infrastructure blip (a rate-limited mise.run, a
GURU sync hiccup, a failed tpm clone). --strict cannot tell them apart, so making it
the default — or wiring it into the weekly unstubbed sweep — reds a run for somebody
else's outage, and a gate that is red for reasons you cannot fix is one everybody
learns to ignore. dotfiles-Fedora's bootstrap-full.yml made the same call, in those
words, for the same reason.
What the sweep needs is not a stricter exit but a FAR-SIDE ASSERTION, and this repo
now ships one: scripts/assert-provisioned.sh asserts that every atom in
install/packages.txt actually put its binary on PATH (hard-fail) and reports the
best-effort tools separately (warn). Run that after a bootstrap. Use --strict when
you want the run itself to carry the exit code.
USAGE
}

while [[ $# -gt 0 ]]; do case "$1" in
  --links-only) LINKS_ONLY=1 ;;
  --no-sync) DO_SYNC=0 ;;
  --dry-run) DRY=1 ;;
  --strict) STRICT=1 ;;
  --no-portage-config) PORTAGE_CONFIG=0 ;;
  --no-extras) EXTRAS=0 ;;
  --user) USER_MODE=1 ;;
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
if ((LINKS_ONLY)) || ((DRY)) || ((USER_MODE)); then
  blib_resolve_su || true
elif ! blib_resolve_su --require; then
  # No escalator, and packages were asked for. Aborting here is the wrong answer:
  # it is exactly the box --user exists for, and the operator cannot fix it by
  # re-running with a password they do not have. Fall back, loudly.
  blib_warn "no way to escalate — falling back to --user (everything into \$HOME, no emerge)"
  USER_MODE=1
fi
# INVARIANT: user mode never escalates. Forcing BLIB_SU empty makes that true by
# construction rather than by every call site remembering — blib_priv then runs
# commands directly, and anything genuinely needing root fails as this user
# instead of sitting on a sudo prompt.
((USER_MODE)) && export BLIB_SU=""

# ── PATH: the per-user bindirs language installers write into ─────────────────
# cargo writes $CARGO_HOME/bin and go writes $GOBIN; neither is on a fresh box's
# bash PATH (they reach PATH via the OS zsh layer — i.e. only inside a Core shell
# that does not exist yet). Without this every `command -v <tool>` guard below
# answers "missing" for a tool that IS installed, and each re-run recompiles viddy
# from source: minutes of work, silently discarded. (It used to recompile
# tree-sitter-cli too, until ::gentoo packaged it and this script stopped building
# it — one fewer source build the guard has to protect, not one fewer reason for it.)
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
if ((LINKS_ONLY == 0)) && ((DRY == 0)) && ((USER_MODE == 0)); then
  trap 'blib_sudo_keepalive_stop' EXIT
  # A FAILED priming is not a reason to abort — it is a reason to fall back.
  #
  # blib_resolve_su answers "is there an escalator BINARY", which is a different
  # question from "can this account actually use it". The gap between those two is
  # the common case, not the exotic one: a corporate laptop or shared host where
  # /usr/bin/sudo exists and the account is simply not in sudoers. There, resolve
  # succeeds, and this priming is the first step that learns the truth:
  #
  #   gerrrt is not in the sudoers file.  This incident will be reported.
  #   ! sudo authentication failed — aborting before provisioning anything
  #   EXIT=1
  #
  # Three different situations reach this branch, and they are NOT equally
  # recoverable — which is why the message below names all of them rather than
  # assuming the first:
  #
  #   not in sudoers   irrecoverable here. No password would work, so aborting is
  #                    the same mistake --user was added to fix, one layer in: the
  #                    operator cannot resolve it by re-running.
  #   wrong password   recoverable — re-run and type it correctly.
  #   no TTY to        recoverable — re-run from a terminal. Common in automation,
  #   prompt on        and the one most likely to surprise someone with full sudo.
  #
  # Falling back suits all three: the recoverable two get a working $HOME install
  # now and a system-wide one whenever they re-run, instead of exit 1 and nothing.
  # But a message that only mentions sudoers would send the other two hunting for a
  # permissions problem they do not have.
  #
  # NB doas: blib_sudo_keepalive_start returns success without priming for anything
  # that is not sudo (doas has no refreshable timestamp), so an unpermitted doas is
  # not caught here — it surfaces per-atom through emerge_install's failure tally
  # instead. Distinguishing "doas needs a password" from "doas will never allow
  # this" is not something `doas -n` can answer, so guessing would break the
  # legitimate password prompt for everyone else.
  if ! blib_sudo_keepalive_start; then
    blib_warn "could not authenticate with ${BLIB_SU:-the privilege escalator} — falling back to --user (everything into \$HOME, no emerge)"
    blib_warn "to provision system-wide instead, re-run from a terminal with a correct password — or, if this account is genuinely not in sudoers, add it (the wheel group) first"
    USER_MODE=1
    export BLIB_SU=""
  fi
fi

# ── emerge options: quiet builds, skip already-installed (idempotent re-runs),
# and pull binary packages IF a binhost is configured (huge time-saver). ────────
EMERGE_OPTS=(--quiet-build=y --noreplace)
if [[ -s /etc/portage/binrepos.conf ]] || ls /etc/portage/binrepos.conf.d/*.conf >/dev/null 2>&1; then
  EMERGE_OPTS+=(--getbinpkg=y)
fi

# _emerge_skip_hint <atom> — say WHICH of the two failures this was.
#
# A per-atom emerge failure is one of two unrelated bugs that look identical in
# the tally, and the old fixed hint only ever described one of them. It blamed a
# missing keyword and pointed at an ".example" keywords file that had been
# renamed away long ago — while a phantom GURU atom (gum: no ebuild in ::gentoo
# or GURU at all) sat in the list for months being neither masked nor keyworded
# but simply nonexistent, its keyword line already installed and unmasking
# nothing. check-packages.sh names this trap in its own header: a nonexistent
# atom "looks exactly like a keyword mask and is never fixed".
#
# `emerge -p` needs no privileges, so it deliberately does NOT go through
# blib_priv — a diagnostic probe must never prompt for a password. It runs only
# on the failure path, once per already-failed atom, so its dependency
# resolution is not on the hot path. If emerge is absent or itself fails, the
# match simply misses and we fall through to the masked/keyworded branch: that is
# the commoner cause and its advice is harmless when wrong.
#
# THERE ARE NOW FOUR OUTCOMES, NOT TWO, and the third is the one that shipped a
# wrong instruction for months (issue #133). `emerge -p dev-util/shellcheck` does
# not complain about shellcheck at all:
#
#   !!! All ebuilds that could satisfy ">=dev-haskell/aeson-1.4.0:=[profile?]"
#   !!! have been masked.
#
# The blocker is a DEPENDENCY, one level down. The old hint printed the requested
# atom's name either way and sent you to gentoo/package.accept_keywords to add a
# line that unmasks nothing — into the very file you would then believe you had
# checked. That is the app-misc/gum trap arriving from the other direction, and it
# is worse than no hint, so this reads which atom the "have been masked" line
# actually quotes and says that instead.

# _atom_of <depspec> — the cat/pn of a Portage dependency spec. Strips a leading
# block (`!`) and range operator, then `[use]`, then `:slot`, then the -rN revision,
# then the trailing -<version> by Portage's own PN/PV rule (a version starts at the
# last `-` followed by a digit) — the same split scripts/check-packages.sh implements
# on the accept_keywords side. Keep the two spellings in step.
#
# THE REVISION HAS TO COME OFF FIRST, and leaving it on is not a cosmetic error. In
# `dev-haskell/aeson-2.2.3.0-r2` the last `-` is followed by `r`, not a digit, so the
# PN/PV rule declines to split and the whole PVR survives as the "atom" — which then
# compares unequal to the atom we asked about and mislabels a self-mask as a
# dependency mask. Portage's own PVR is PV plus an optional -rN; strip in that order.
#
# `${spec#'~'}` is quoted deliberately. Unquoted, bash TILDE-EXPANDS the pattern in
# `${spec#~}` — it tries to strip $HOME from the front of a Portage atom and leaves
# the `~` exactly where it was, which is how `~app-shells/zoxide-0.9.8` came out of
# here still carrying its operator.
_atom_of() {
  local spec="$1"
  spec="${spec#'!'}"
  spec="${spec#'!'}"
  spec="${spec#'>'}"
  spec="${spec#'<'}"
  spec="${spec#'='}"
  spec="${spec#'~'}"
  spec="${spec%%[*}"
  spec="${spec%%:*}"
  local rev="${spec##*-}"
  if [[ "$spec" == *-* && "$rev" =~ ^r[0-9]+$ ]]; then spec="${spec%-*}"; fi
  local ver="${spec##*-}"
  if [[ "$spec" == *-* && "$ver" =~ ^[0-9] ]]; then spec="${spec%-*}"; fi
  printf '%s' "$spec"
}

_emerge_skip_hint() {
  local a="$1" out masked reason blocker
  # `|| true`: a refused emerge exits non-zero, which is precisely the case we are
  # here to explain. Unguarded, the substitution would abort the run under `set -e`.
  out="$(emerge -p "$a" 2>&1 || true)"

  if printf '%s\n' "$out" | grep -q 'there are no ebuilds to satisfy'; then
    printf 'no such ebuild in any enabled repo — typo, wrong category, or an overlay that is not enabled'
    return 0
  fi

  # A BLOCKER is not a mask, and the difference is the whole fix. Portage says:
  #
  #   [blocks B     ] dev-util/shellcheck ("dev-util/shellcheck" is soft blocking
  #                   dev-util/shellcheck-bin-0.11.0)
  #
  # Nothing here is masked and no keyword file can help — an ALREADY-INSTALLED
  # package has to come off first. This is a live migration, not a hypothetical:
  # dev-util/shellcheck-bin RDEPENDs !dev-util/shellcheck, so any box that got the
  # source atom in before this change (by hand-unmasking the whole GHC chain, which
  # the old hint invited) hits exactly this on its next bootstrap.
  #
  # The advice stops at naming the unmerge. Removing a package the operator
  # installed is not this script's call — the same line it already holds for the
  # stale ~/.cargo/bin/jj a few hundred lines down.
  blocker="$(printf '%s\n' "$out" |
    sed -n 's/.*("\([^"]*\)" is \(soft \)\?blocking .*/\1/p' | head -n1)"
  if [[ -n "$blocker" ]]; then
    printf 'BLOCKED by an already-installed package, not masked — no keyword file can fix this. Remove the conflicting package first: emerge --unmerge %s' "$blocker"
    return 0
  fi

  # The quoted spec out of `All ebuilds that could satisfy "<spec>" have been masked`.
  masked="$(printf '%s\n' "$out" |
    sed -n 's/.*All ebuilds that could satisfy "\([^"]*\)".*/\1/p' | head -n1)"
  # The parenthesised cause from the first `- <pkg> (masked by: ...)` line — the
  # actionable half, because it separates a keyword mask from a package.mask from a
  # licence, and those three want three different fixes.
  # Greedy on BOTH sides so a nested paren survives: Portage really does write
  # `(masked by: 1password EULA license(s))`, and a non-greedy [^)]* cuts it to
  # "license(s" — a hint that looks like the output is corrupted.
  reason="$(printf '%s\n' "$out" |
    sed -n 's/.*(masked by: \(.*\))/\1/p' | head -n1)"

  if [[ -n "$masked" ]] && [[ "$(_atom_of "$masked")" != "$(_atom_of "$a")" ]]; then
    printf 'blocked by a masked DEPENDENCY, not by its own keyword: %s%s. Adding %s to gentoo/package.accept_keywords will NOT help — decide whether that dependency is worth unmasking, or whether another atom ships the same tool' \
      "$masked" "${reason:+ (masked by: $reason)}" "$a"
    return 0
  fi

  printf "masked or keyworded%s — run 'emerge -p %s' for the exact keyword or licence, then add it to gentoo/package.accept_keywords" \
    "${reason:+, by: $reason}" "$a"
}

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
      blib_note_fail "emerge skipped: $a ($(_emerge_skip_hint "$a"))"
  done
}

# ── a cause, not just a verdict ───────────────────────────────────────────────
# Every best-effort step below used to run with `>/dev/null 2>&1`, so a failure
# reached the ledger as a bare verdict with nothing to act on. That is why the first
# sweep to finish could only report `ouch: cargo build failed` — the reason (a
# vendored C++ dep built with -stdlib=libc++) was written to /dev/null, and the
# operator was left to reproduce an hour-long run to read it (issue #133).
#
# So: log to a file, quote the tail in the failure line, and NAME the file so the
# whole thing is there. The log survives ONLY on failure — the same rule
# _user_build_zsh already applies to a failed build tree, and for the same reason:
# something you are told to go and read must still exist when you get there.
# The redirect target falls back to /dev/null if mktemp fails, so a read-only or
# full $TMPDIR degrades to the old behaviour rather than aborting the bootstrap.
_log_path() { # <slug>
  mktemp "${TMPDIR:-/tmp}/dotfiles-gentoo-$1.XXXXXX.log" 2>/dev/null || true
}

# The last few lines, flattened to fit one ledger entry. Anything longer belongs in
# the file, whose path the caller prints alongside this.
_log_tail() { # <file>
  [[ -n "${1:-}" && -s "$1" ]] || return 0
  local t
  t="$(tail -n 5 "$1" | tr '\n\t' '  ' | tr -s ' ' | cut -c1-240)"
  # Trim the edges: build output is indented, and a ledger line reading
  # "failed —   Compiling ..." looks like the message itself is broken.
  t="${t#"${t%%[![:space:]]*}"}"
  t="${t%"${t##*[![:space:]]}"}"
  printf '%s' "$t"
}

# ── GURU overlay: a handful of core-doctor tools aren't in the main tree but
# ARE in GURU. Enable GURU (once, best-effort) then emerge them tolerant of
# failure so a masked/absent atom never aborts the bootstrap. ────────────────────

# Is GURU known to Portage? (eselect repository list -i, or a repos.conf entry /
# synced repo on disk.) Asked in two places, so it is one function.
_guru_available() {
  eselect repository list -i 2>/dev/null | grep -qw guru || [[ -d /var/db/repos/guru ]]
}

# Enable + sync GURU, ONCE per run. The once-guard is not a micro-optimisation: two
# call sites now reach this (guru_install and guru_extras_install), and without it a
# box that cannot enable the overlay would record the SAME failure twice, turning
# one problem into two entries in a ledger whose whole value is that its length
# means something.
_GURU_ENABLE_TRIED=0
_guru_enable() {
  ((_GURU_ENABLE_TRIED)) && return 0
  _GURU_ENABLE_TRIED=1
  _guru_available && return 0
  blib_say "enabling the GURU overlay (for sd/glow/xh/carapace/op/ouch)"
  local log
  log="$(_log_path guru-enable)"
  if blib_priv eselect repository enable guru >"${log:-/dev/null}" 2>&1 &&
    blib_priv emaint sync -r guru >>"${log:-/dev/null}" 2>&1; then
    [[ -n "$log" ]] && rm -f "$log"
    return 0
  fi
  local cause
  cause="$(_log_tail "$log")"
  blib_note_fail "could not enable/sync the GURU overlay — its tools are skipped${cause:+ — $cause}${log:+ (full log: $log)} (needs app-eselect/eselect-repository; enable later with: eselect repository enable guru && emaint sync -r guru)"
  return 0
}

guru_install() {
  local -a atoms=("$@")
  _guru_enable
  # Only attempt the emerge if GURU is actually available now. Reuse the repo's
  # per-atom-tolerant emerge_install so one masked/keyworded GURU atom (e.g.
  # app-misc/yazi) doesn't stop emerge early and skip the rest.
  if _guru_available; then
    blib_say "emerge GURU tools (best-effort): ${atoms[*]}"
    emerge_install "${atoms[@]}"
  fi
}

# ── the opt-in extras that come from the OVERLAY: the third seam ──────────────
# There are now three atom lists in this script and they differ along two axes —
# which tree the atom comes from, and whether --no-extras skips it:
#
#   install/packages.txt      ::gentoo, unconditional
#   guru_install              GURU,     unconditional
#   extras_install            ::gentoo, opt-in
#   guru_extras_install       GURU,     opt-in   <- this one
#
# app-arch/ouch is the first atom in the fourth cell, so neither existing seam fits:
# guru_install would install it on a --no-extras run (the one thing that flag
# promises not to do), and extras_install is validated against ::gentoo by
# scripts/check-packages.sh check 7, where a GURU-only atom reads as the
# app-misc/gum bug. Hence a distinct name, which costs one line and gives check 9 an
# unambiguous target — exactly the argument extras_install already makes for itself.
#
# _guru_enable rather than a bare emerge_install: guru_install has normally run by
# now and the guard makes this a no-op, but --only/--skip and future reordering must
# not be able to leave this call reaching for an overlay nobody enabled.
guru_extras_install() {
  _guru_enable
  if _guru_available; then
    blib_say "emerge opt-in GURU tools (best-effort): $*"
    emerge_install "$@"
  else
    blib_note_fail "GURU is not available — the opt-in overlay atoms were skipped: $*"
  fi
}

# ── the opt-in extras that ARE packaged: a named seam for the gate ────────────
# extras_install is a one-line pass-through to emerge_install and exists for one
# reason: scripts/check-packages.sh validates the atoms bootstrap.sh emerges by
# parsing the CALL, not by keeping a second copy of the list (a second copy is a
# second thing to forget — it is how app-misc/gum survived). Calling
# emerge_install directly from the extras block would be unparseable: it is also
# called as `emerge_install "${atoms[@]}"` in two other places, so a parser aimed
# at that name emits `"${atoms[@]}"` as a bogus atom and fails the shape check.
# A distinct name gives the gate an unambiguous target, exactly as guru_install
# already does — and costs one line.
extras_install() { emerge_install "$@"; }

# ── cargo-install fallback: Rust CLIs packaged nowhere on Gentoo ───────────────
# Same shape as _dotfiles_go_install below: guarded on the binary already existing
# (which now WORKS, because blib_user_bindirs_on_path put ~/.cargo/bin on PATH —
# without it every one of these rebuilt from source on every run), never aborts,
# and records a failure rather than printing one into the scroll.
#
# The crate name is NOT always the binary name and getting it wrong is silent:
# `watchexec-cli` provides `watchexec` — plain `watchexec` is the library and
# installing it gives you no binary at all (core/PORTING-MATRIX.md footnote 25).
#
# jj used to be the other example here (`jj-cli`, because the `jujutsu` crate is
# an abandoned redirect stub). It is gone from this function on purpose: ::gentoo
# packages the VCS as dev-vcs/jj, so the extras block emerges the atom and this
# function is never passed a jj crate name. The trap is still real and still
# documented — .github/ISSUE_TEMPLATE/feature_request.md keeps `jj-cli → jj` as
# its example — but a live warning about an argument that no longer exists is a
# comment describing a former state, which is the bug this repo keeps fixing.
_dotfiles_cargo_install() { # <crate> <binary-name>
  [ "$#" -ge 2 ] || return 0
  if command -v "$2" >/dev/null 2>&1; then return 0; fi
  if ! command -v cargo >/dev/null 2>&1; then
    blib_note_fail "$2: needs cargo (dev-lang/rust-bin, in packages.txt) — install later: cargo install --locked $1"
    return 0
  fi
  blib_say "$2 (cargo build — crate: $1)"
  local log cause
  log="$(_log_path "cargo-$2")"
  if cargo install --locked "$1" >"${log:-/dev/null}" 2>&1; then
    [[ -n "$log" ]] && rm -f "$log"
    return 0
  fi
  cause="$(_log_tail "$log")"
  blib_note_fail "$2: cargo build failed${cause:+ — $cause}${log:+ (full log: $log)} — retry later: cargo install --locked $1"
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
  local log cause rc=0
  log="$(_log_path "go-$2")"
  if command -v go >/dev/null 2>&1; then
    GOBIN="$gobin" go install "$1" >"${log:-/dev/null}" 2>&1 || rc=1
  elif command -v mise >/dev/null 2>&1; then
    GOBIN="$gobin" mise exec go@latest -- go install "$1" >"${log:-/dev/null}" 2>&1 || rc=1
  else
    [[ -n "$log" ]] && rm -f "$log"
    blib_note_fail "$2: needs Go — install later with: GOBIN=$gobin go install $1"
    return 0
  fi
  if ((rc == 0)); then
    [[ -n "$log" ]] && rm -f "$log"
    return 0
  fi
  cause="$(_log_tail "$log")"
  blib_note_fail "$2: go install failed${cause:+ — $cause}${log:+ (full log: $log)} — retry later: GOBIN=$gobin go install $1"
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
#     up under /var/lib/dotfiles-Gentoo/portage-backups/ before being replaced.
#     NOT alongside it: Portage reads every file in package.accept_keywords/, so a
#     backup left there is live config forever and a deleted line never actually
#     goes away;
#   • opt-out with --no-portage-config, previewable with --dry-run;
#   • per-atom lines only. No `*/* ~arch`.
#
# __ARCH__ is rendered from `portageq envvar ARCH` so this is correct on arm64 or
# any other arch, not just amd64.
# Where a replaced /etc/portage file is preserved. NOT under /etc/portage — see
# the backup block below for what that cost.
BACKUP_DIR=/var/lib/dotfiles-Gentoo/portage-backups

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
    # THE BACKUP MUST NOT LAND IN /etc/portage. This used to write
    # "$dst.pre-dotfiles.<epoch>" — i.e. straight into
    # /etc/portage/package.accept_keywords/, which Portage reads IN FULL: every
    # file in that directory is live config, whatever it is called. So each backup
    # became a permanent second copy of the keyword list, and REMOVING a line from
    # the file we ship stopped removing it from the box. Measured on a provisioned
    # machine: three backups, every one still carrying the `dev-util/shellcheck`
    # line this repo had deleted, so the deletion was a silent no-op there.
    #
    # That is this repo's recurring bug in its purest form — a change that looks
    # applied and is not — and it was hiding inside the safety mechanism. Backups
    # go to $BACKUP_DIR (under /var/lib), which nothing scans.
    blib_priv mkdir -p "$BACKUP_DIR" || {
      blib_note_fail "portage config: could not create $BACKUP_DIR — refusing to back up $dst inside /etc/portage (Portage would read the backup as live config), so $dst is left untouched"
      return 0
    }
    # RETURN on a failed backup: writing anyway would destroy the content the
    # backup exists to preserve, while logging "leaving it untouched".
    blib_priv cp -p "$dst" "$BACKUP_DIR/${2//\//_}-90-dotfiles-Gentoo.$(date +%s)" || {
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

# Backups this repo left in /etc/portage BEFORE the fix above, which are still
# live config on every box provisioned by an older bootstrap. Fixing where new
# backups go does nothing for them — and a box carrying one is precisely a box
# where deleting a keyword line has no effect, which is the failure this whole
# path exists to stop.
#
# WARN, DO NOT DELETE. These are the operator's only copy of whatever was in
# /etc/portage before this repo first ran; a bootstrap that removes the backup it
# told you to keep is worse than the bug. blib_warn and not blib_note_fail for the
# same reason the stale ~/.cargo/bin/jj warning uses it: this is a leftover from an
# EARLIER run, not a step of this one that failed, and feeding --strict a condition
# we have deliberately chosen not to fix automatically would make it permanently red.
_warn_stale_portage_backups() { # <portage-subdir>
  local dir="/etc/portage/$1" f n=0
  [[ -d "$dir" ]] || return 0
  for f in "$dir"/*.pre-dotfiles.*; do
    [[ -e "$f" ]] || continue
    n=$((n + 1))
  done
  ((n)) || return 0
  blib_warn "$dir holds $n backup file(s) named *.pre-dotfiles.* that an older bootstrap left THERE — and Portage reads every file in that directory, so each one is still live config. Any keyword line this repo has since removed is still in effect on this box (dev-util/shellcheck is the one that matters today). Review and delete them: ls $dir/*.pre-dotfiles.*"
  blib_warn "new backups now go to $BACKUP_DIR instead; these are left alone because they may be your only copy of what was in $dir before this repo first ran"
}

install_portage_config() {
  ((PORTAGE_CONFIG)) || {
    blib_say "--no-portage-config: leaving /etc/portage alone (keyword/licence-masked atoms will be skipped)"
    return 0
  }
  _portage_conf_install "$DOTFILES/gentoo/package.accept_keywords" package.accept_keywords
  _portage_conf_install "$DOTFILES/gentoo/package.license" package.license
  _warn_stale_portage_backups package.accept_keywords
  _warn_stale_portage_backups package.license
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

# ══ the no-root path ══════════════════════════════════════════════════════════
# Everything below installs into $HOME and touches nothing else. It exists because
# "you need root" is not an answer on an account that will never have root — and
# because almost none of this stack actually requires it: mise ships prebuilt
# binaries, cargo and go write into $HOME by default, and zsh builds from source
# with the toolchain a Gentoo box already has.

# ZSH_PIN / ZSH_SHA256 — zsh is in no binary registry, and it is the ONE hard
# dependency: without it there is no Core shell at all, so `core doctor` cannot
# even run. Building it is ~2 minutes with the compiler already present.
#
# The tarball is pinned by version AND SHA-256, matching the fleet's existing idiom
# for unpackaged tools (core/scripts/tool-versions.env pins shellcheck and shfmt
# the same way). The hash below was taken from the canonical zsh.org tarball and
# checked against dana's PGP signature (key 7CA7ECAAF06216B90F894146ACF8146CAE8CBBC4,
# "Good signature") at the time of pinning — so a bump means re-verifying the
# signature, not just copying a new number.
ZSH_PIN="5.9.2"
ZSH_SHA256="36fa734374b44783582cec09bcd67822e2f992c779ec1624ab5596df078d2f81"

_user_build_zsh() {
  if command -v zsh >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/zsh" ]]; then
    blib_say "zsh already present — skipping the source build"
    return 0
  fi
  # DRY must return BEFORE anything below: this function downloads, compiles and
  # `make install`s into ~/.local, which is the single most invasive thing in user
  # mode. Note where the bug hid — on a box that ALREADY has zsh the early return
  # above fires first, so a --dry-run tested on a provisioned machine looks
  # perfectly well behaved. Only a fresh box would have found it, by having zsh
  # silently installed by a flag documented as changing nothing.
  if ((DRY)); then
    if command -v gcc >/dev/null 2>&1 || command -v cc >/dev/null 2>&1; then
      blib_say "would build zsh $ZSH_PIN from source into ~/.local (pinned, SHA-256 verified before unpacking)"
    else
      # A warning, not blib_note_fail: a preview must not add to the failure tally
      # the real run reports. Still worth saying loudly — with no compiler this box
      # cannot get zsh at all, and without zsh no part of Core loads.
      blib_warn "would NOT be able to build zsh — no C compiler found, and without zsh none of Core loads"
    fi
    return 0
  fi
  if ! command -v gcc >/dev/null 2>&1 && ! command -v cc >/dev/null 2>&1; then
    blib_note_fail "zsh: no C compiler — cannot build it, and without zsh none of Core loads"
    return 0
  fi
  local tarball="zsh-${ZSH_PIN}.tar.xz" workdir
  workdir="$(mktemp -d)" || {
    blib_note_fail "zsh: could not create a build directory"
    return 0
  }
  blib_say "zsh $ZSH_PIN (source build — no binary release exists for any registry)"
  (
    cd "$workdir" || exit 1
    curl -fsSLO "https://www.zsh.org/pub/$tarball" || exit 1
    # Verify BEFORE unpacking: a bad tarball must never reach tar, let alone make.
    printf '%s  %s\n' "$ZSH_SHA256" "$tarball" | sha256sum -c - >/dev/null 2>&1 || exit 2
    tar xf "$tarball" || exit 1
    cd "zsh-${ZSH_PIN}" || exit 1
    ./configure --prefix="$HOME/.local" --enable-multibyte >/dev/null 2>&1 || exit 3
    make -j"$(nproc 2>/dev/null || echo 2)" >/dev/null 2>&1 || exit 3
    make install >/dev/null 2>&1 || exit 3
  )
  # KEEP the build tree on a build failure, discard it otherwise. The failure hint
  # names $workdir so you can go and read config.log or re-run make by hand — which
  # it previously did while the unconditional rm below deleted that directory a line
  # later, making the one actionable message in this function a dead end.
  #
  # A checksum mismatch is the opposite case: the tarball is untrusted, there is
  # nothing there worth inspecting, and leaving it invites someone to build it
  # anyway. That one is removed.
  local keep=0
  case "$?" in
    0) blib_ok "zsh $ZSH_PIN installed to ~/.local/bin/zsh" ;;
    2) blib_note_fail "zsh: SHA-256 mismatch on $tarball — REFUSED and deleted (expected $ZSH_SHA256). Not a transient failure; do not retry blindly." ;;
    3)
      keep=1
      blib_note_fail "zsh: build failed — the tree is LEFT at $workdir for inspection (start with config.log; missing ncurses headers are the usual cause). Retry: cd $workdir/zsh-${ZSH_PIN} && ./configure --prefix=\$HOME/.local && make && make install"
      ;;
    *) blib_note_fail "zsh: download or unpack failed — retry later, or build $tarball by hand" ;;
  esac
  ((keep)) || rm -rf "$workdir" 2>/dev/null || true
  return 0
}

# The mise tool manifest goes to conf.d, NEVER to ~/.config/mise/config.toml —
# that path is a symlink into the vendored core/ subtree, so writing it (which is
# exactly what `mise use -g` does) would silently edit Core. Same install rules as
# the /etc/portage files: idempotent, backed up, previewable.
_user_install_mise_tools() {
  local src="$DOTFILES/gentoo/mise-tools.toml"
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}/mise/conf.d"
  local dst="$dir/10-dotfiles-Gentoo.toml"
  [[ -r "$src" ]] || {
    blib_note_fail "user mode: $src is missing — no tool manifest to install"
    return 0
  }
  if [[ -e "$dst" ]] && cmp -s "$src" "$dst"; then
    blib_say "mise tool manifest already current"
  elif ((DRY)); then
    blib_say "would install $dst (the mise tool manifest)"
  else
    mkdir -p "$dir"
    [[ -e "$dst" ]] && cp -p "$dst" "$dst.pre-dotfiles.$(date +%s)"
    cp "$src" "$dst"
    blib_ok "mise tool manifest -> $dst"
  fi
  ((DRY)) && {
    blib_say "would run: mise install (prebuilt binaries into ~/.local/share/mise)"
    return 0
  }
  # `mise install` with no argument installs what the merged config DECLARES —
  # which includes Core's language runtimes. That is deliberate: they are declared
  # in Core's own config and a box that wants them should get them. auto_install
  # stays false, so nothing installs behind your back on a `cd`.
  blib_say "mise install (prebuilt binaries — no compiler, no privileges)"
  mise install || blib_note_fail "mise install: one or more tools failed — re-run 'mise install' to see which"
}

# ~/.zshenv — the ordering fix. Core's 00-tools.zsh probes each tool with
# `command -v` and sets HAVE_* BEFORE it runs `mise activate` later in the same
# file, so a tool that exists only under mise is invisible to the probe: every
# HAVE_* stays unset, 20-aliases.zsh skips every guarded alias, and the
# starship/atuin/zoxide/carapace inits never run. `core doctor` then reports ✓ for
# all of them (it runs from the prompt, after activation) while the shell uses
# none of them — measured here as 41 ✓ tools next to `ll='ls -lah'`.
#
# That is dotfiles-core#425. The fix must land before the FIRST Core fragment, and
# both the OS layer (80-os.zsh) and the host layer (99-local.zsh) are far too
# late — hence .zshenv, which zsh reads first, always. Remove this once Core does
# it in the entry file it already generates.
#
# Written only when absent or when it is still ours to write: a hand-authored
# .zshenv is left alone, because it is a file this repo does not own.
_user_write_zshenv() {
  local rc="$HOME/.zshenv" marker="dotfiles-Gentoo user-mode PATH"
  if [[ -e "$rc" ]] && ! grep -q "$marker" "$rc" 2>/dev/null; then
    blib_warn "$rc exists and is not ours — leaving it alone. For mise-installed tools to be seen by Core's probes, it must put \$XDG_DATA_HOME/mise/shims (and \$HOME/.local/bin, \$HOME/.cargo/bin) on \$PATH."
    return 0
  fi
  if ((DRY)); then
    blib_say "would write ~/.zshenv (mise shims + user bindirs on PATH before Core loads)"
    return 0
  fi
  cat >"$rc" <<'ZENV'
# ~/.zshenv — dotfiles-Gentoo user-mode PATH. Read by EVERY zsh, before ~/.zshrc
# and before any Core fragment. Regenerated by ./bootstrap.sh --user.
#
# Core's zsh/00-tools.zsh probes tools with `command -v` and sets HAVE_* BEFORE it
# runs `mise activate` later in the same file. Without the lines below, a tool that
# exists only under mise (or cargo, or go) is invisible to that probe: HAVE_* stays
# unset, every guarded alias in 20-aliases.zsh is skipped, and the starship/atuin/
# zoxide/carapace inits never run — while `core doctor`, which runs later, reports
# ✓ for all of them. Upstream: dotfiles-core#425.
_mise_shims="${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims"
[[ -d $_mise_shims ]] && path=("$_mise_shims" $path)
unset _mise_shims
[[ -d $HOME/.local/bin ]] && path=("$HOME/.local/bin" $path)
[[ -d $HOME/.cargo/bin ]] && path=("$HOME/.cargo/bin" $path)
export PATH
ZENV
  blib_ok "$rc written (mise shims + user bindirs ahead of Core's probes)"
}

# The login shell, without root. blib_set_login_shell runs `chsh -s <zsh>`, but
# chsh only accepts a shell listed in /etc/shells and adding a line there needs
# root — so on this account the login shell is stuck as bash and a fresh login
# never reaches Core. exec'ing from the login profile is the same outcome with no
# privileges. Appended once, guarded, and reversible by deleting the block.
_user_login_handoff() {
  local prof="$HOME/.bash_profile" marker="dotfiles-Gentoo zsh handoff"
  local zsh_path="$HOME/.local/bin/zsh"
  [[ -x "$zsh_path" ]] || return 0
  if [[ -e "$prof" ]] && grep -q "$marker" "$prof" 2>/dev/null; then
    blib_say "bash->zsh login handoff already installed"
    return 0
  fi
  if ((DRY)); then
    blib_say "would append a guarded bash->zsh handoff to ~/.bash_profile"
    return 0
  fi
  [[ -e "$prof" ]] && cp -p "$prof" "$prof.pre-dotfiles.$(date +%s)"
  cat >>"$prof" <<'PROF'

# ── dotfiles-Gentoo zsh handoff ───────────────────────────────────────────────
# chsh cannot point at a $HOME zsh (it only accepts shells listed in /etc/shells,
# and editing that needs root), so hand off from the login profile instead.
# Guards, in order: already-zsh (never loop); interactive only (scp/rcp must not
# be handed a different shell); a real terminal; the binary actually exists, so a
# removed zsh leaves a WORKING bash login rather than a machine you cannot log
# into; and NO_ZSH_HANDOFF=1 as an escape hatch.
if [[ -z "$ZSH_VERSION" && $- == *i* && -t 1 && -z "$NO_ZSH_HANDOFF" \
   && -x "$HOME/.local/bin/zsh" ]]; then
  exec "$HOME/.local/bin/zsh" -l
fi
PROF
  blib_ok "bash->zsh login handoff appended to ~/.bash_profile (NO_ZSH_HANDOFF=1 opts out)"
}

provision_user() {
  blib_say "USER MODE — nothing outside \$HOME is touched, and emerge is not used"
  # mise first: it supplies most of the stack.
  if ! command -v mise >/dev/null && [[ ! -x "$HOME/.local/bin/mise" ]]; then
    if ((DRY)); then
      blib_say "would install mise (official installer)"
    else
      blib_say "mise (official installer)"
      curl -fsSL https://mise.run | sh >/dev/null 2>&1 ||
        blib_note_fail "mise: installer failed — without it most of the user-mode stack cannot install"
    fi
  fi
  blib_user_bindirs_on_path   # pick up a mise that was just installed
  _user_install_mise_tools
  _user_build_zsh

  # The four rows with no mise registry entry. tree-sitter/viddy come from mise in
  # user mode, so they are not repeated here.
  if ((DRY)); then
    blib_say "would cargo-install: procs, git-absorb"
    blib_say "would go-install: sesh"
    blib_say "(ouch comes from mise's ubi backend, not cargo — see gentoo/mise-tools.toml)"
  else
    _dotfiles_cargo_install procs procs
    _dotfiles_cargo_install git-absorb git-absorb
    _dotfiles_go_install github.com/joshmedeski/sesh/v2@latest sesh
  fi

  _user_write_zshenv
  _user_login_handoff
  return 0
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
    blib_say "would install mise / viddy where missing (tree-sitter-cli is an atom above)"
    blib_say "would go-install: gron, sesh, shfmt"
    if ((EXTRAS)); then
      # --dry-run promises the full plan, so name both paths: "emerged" vs "built
      # from source" is the single most operationally relevant difference between
      # them (one honours --getbinpkg, the other can only ever compile locally).
      blib_say "would emerge the opt-in atoms: dev-vcs/jj (::gentoo) and app-arch/ouch (GURU) — both ~arch, see gentoo/package.accept_keywords"
      blib_say "would cargo-build the opt-in set: ast-grep, jnv, watchexec"
    else
      blib_say "--no-extras: would skip dev-vcs/jj and app-arch/ouch, and ast-grep / jnv / watchexec"
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
  # viddy backs the watch->viddy alias. tree-sitter-cli was the other one here and
  # is gone on purpose: ::gentoo carries dev-util/tree-sitter-cli 0.26.11 STABLE,
  # which clears nvim-treesitter's 0.26.1 floor, so it is an atom in
  # install/packages.txt and Portage owns the upgrade. NB an already-provisioned box
  # keeps its ~/.cargo/bin/tree-sitter until you remove it — that binary is what
  # _dotfiles_cargo_install's `command -v` guard was matching, and it shadows the
  # emerged one on PATH.
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

  # ── opt-in extras (--no-extras skips these) ──────────────────────────────────
  # Every one is HAVE_*-gated in Core, so skipping them costs nothing but a ✗ in
  # `core doctor` — which is precisely why they were never installed and the
  # doctor was never clean. jj is additive and never replaces git.
  #
  # THREE cargo crates packaged nowhere on Gentoo, plus TWO that ARE packaged and
  # are emerged instead: dev-vcs/jj from ::gentoo and app-arch/ouch from GURU. Both
  # moved off cargo for the same reason — it hands Portage the upgrade, puts the
  # binary in /usr/bin, and lets a binhost supply it, none of which `cargo install`
  # can do. (For ouch there was a second, blunter reason: the cargo build does not
  # work here at all. See the note at the call.)
  #
  # It stays HERE rather than moving up to install/packages.txt: packages.txt is
  # the UNCONDITIONAL emerge, and jj is opt-in — an atom there would install on a
  # --no-extras run, which is the one thing that flag promises not to do.
  if ((EXTRAS)); then
    extras_install dev-vcs/jj
    # Migration wart: a box bootstrapped before this change has ~/.cargo/bin/jj from
    # `cargo install jj-cli`, and Core puts ~/.cargo/bin AHEAD of /usr/bin on PATH
    # (blib_user_bindirs_on_path). The emerge above succeeds, `jj` still resolves to
    # the stale cargo build, and nothing will ever upgrade it — silent, and it looks
    # like it worked.
    #
    # Say so; do NOT remove it. ~/.cargo/bin is the operator's, not ours, and a
    # bootstrap that deletes a binary it did not install is one you cannot trust.
    # blib_warn and NOT blib_note_fail: note_fail feeds --strict, and this is a
    # leftover from an earlier run rather than a step of THIS one that failed —
    # note_fail would make --strict permanently red on every provisioned box, for
    # a condition we have deliberately chosen not to fix automatically.
    #
    # Inside the EXTRAS branch on purpose: under --no-extras nothing emerges
    # /usr/bin/jj, so the cargo binary shadows nothing and the advice is noise.
    if [[ -x "$HOME/.cargo/bin/jj" ]]; then
      blib_warn "jj: ~/.cargo/bin/jj (an old 'cargo install jj-cli') shadows the emerged /usr/bin/jj on PATH and will never be upgraded — remove it with: cargo uninstall jj-cli"
    fi
    # ouch is app-arch/ouch from GURU, NOT `cargo install ouch`. That cargo build
    # cannot succeed on a GCC/libstdc++ box: its default `unrar` feature pulls
    # unrar-ng-sys, whose build.rs unconditionally adds -stdlib=libc++. This repo
    # had written that cause down in gentoo/mise-tools.toml since user mode was
    # built — the privileged path simply never read its own note, so every run
    # burned a compile and logged "cargo build failed" (issue #133).
    #
    # And the rationale it was kept under does not survive contact either: GURU's
    # ebuild is 0.8.1, the SAME version as upstream's latest release, so "cargo for
    # upstream-latest" bought no version and cost the tool. Its src_prepare() seds
    # that exact flag out. Same move dev-vcs/jj made, one tree over.
    guru_extras_install app-arch/ouch
    _dotfiles_cargo_install ast-grep ast-grep
    _dotfiles_cargo_install jnv jnv
    _dotfiles_cargo_install watchexec-cli watchexec
  else
    blib_say "--no-extras: skipping dev-vcs/jj and app-arch/ouch, and ast-grep / jnv / watchexec"
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
  # The pending-update counter os/gentoo.capabilities declares as PKG_COUNT_PENDING.
  # It has to be reachable BY NAME: a declaration is data, so Core never expands a
  # path out of it, and the maint runner is a different process with a baked PATH.
  # ~/.local/bin is the one directory both callers already have — the interactive
  # shell prepends it (os/gentoo.zsh) and it is the first entry in the runner's PATH
  # (core/maint/dotfiles-maint.sh) — so the symlink is what makes the declaration
  # true. blib_link honours BLIB_DRY, so --dry-run stays a preview.
  blib_link "$DOTFILES/scripts/pkg-pending.sh" "$HOME/.local/bin/gentoo-pkg-pending"
  # shellcheck disable=SC2119  # no args is intentional — writes the default module set
  blib_write_zshrc_loader
  # blib_set_login_shell runs `chsh -s <zsh>`, which needs the shell to be listed
  # in /etc/shells — a root-only edit. In user mode that is guaranteed to fail, and
  # it fails EXPENSIVELY: observed burning three sudo password attempts (with the
  # lockout risk that carries) before warning. _user_login_handoff already covers
  # the same ground with no privileges, so skip it outright.
  if ((USER_MODE)); then
    blib_say "user mode: not touching the login shell (chsh needs /etc/shells, which is root-only) — the ~/.bash_profile handoff does this instead"
  else
    blib_set_login_shell
  fi
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

if ((LINKS_ONLY)); then
  :
elif ((USER_MODE)); then
  provision_user
else
  provision
fi
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
