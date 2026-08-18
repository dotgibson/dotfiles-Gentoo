#!/usr/bin/env bash
# dotfiles-Gentoo/scripts/check-packages.sh
# ──────────────────────────────────────────────────────────────────────────────
# Validate install/packages.txt against a real Portage tree, and validate that
# gentoo/package.accept_keywords covers exactly what needs covering.
#
# WHY THIS EXISTS. Every mistake this catches has already been made here and was
# caught by hand, then written up as a comment warning the next person:
#
#   • install/packages.txt: "Do NOT add dev-vcs/jujutsu or dev-go/shfmt — neither
#     atom exists"  ← a nonexistent atom emerges as a `skipped:` line, i.e. it
#     looks exactly like a keyword mask and is never fixed.
#   • "direnv is GURU-only on Gentoo (app-shells/direnv, NOT dev-util/direnv,
#     which does not exist)"  ← same failure, wrong category.
#   • app-shells/zoxide and sys-fs/duf have NO stable ebuild, so on a stable
#     profile they cannot install at all — which is invisible until a fresh box
#     finishes "complete" without them.
#   • app-misc/gum sat in bootstrap.sh's guru_install list for months with no
#     ebuild in ::gentoo OR GURU, failing every single run — and we shipped an
#     accept_keywords line for it, so the file you were told to check already had
#     the entry you were told to add. Checks 1-4 could not see any of it: they
#     read install/packages.txt, and the GURU list is hard-coded in bootstrap.sh.
#
# A comment cannot fail a build. This can.
#
# Checks:
#   1. shape       — every entry is category/name
#   2. existence   — the atom exists in the tree
#   3. reachability— an atom with no stable keyword for this ARCH is listed in
#                    gentoo/package.accept_keywords (else a stable profile skips it)
#   4. staleness   — an accept_keywords entry whose atom HAS gone stable (advisory:
#                    the line is now dead weight and should be dropped)
#   5. GURU list   — every atom bootstrap.sh emerges from GURU exists in GURU (or
#                    has graduated to ::gentoo, which is advisory: it should move
#                    to packages.txt), and is reachable on a stable profile
#   6. dead keys   — an accept_keywords line whose atom exists in NEITHER tree.
#                    That line unmasks nothing; it is how gum stayed invisible.
#
# Checks 5 and 6 need the GURU overlay. Point GURU_TREE at a checkout, or sync it
# (eselect repository enable guru && emaint sync -r guru). Without it they SKIP —
# and --require-tree makes that skip fatal, for the reason spelled out below.
#
# Usage:
#   ./scripts/check-packages.sh                # check, exit non-zero on a real problem
#   ./scripts/check-packages.sh --quiet        # only report problems
#   ./scripts/check-packages.sh --require-tree # a missing tree is FATAL, not a skip
#   GURU_TREE=/path/to/guru ./scripts/check-packages.sh
#
# Needs a synced ::gentoo tree. Without one it SKIPS (exit 0) with a message
# rather than failing — so it is safe to run anywhere, including a laptop that has
# never synced.
#
# That default is wrong in exactly one place: CI. A gate whose "no tree" path is
# exit 0 goes GREEN having validated nothing the moment emerge-webrsync moves,
# changes, or half-succeeds — the same shape as a fixture that manufactures the
# spelling its check accepts. --require-tree inverts it, so the workflow asserts
# the invariant using this script's OWN tree resolution rather than duplicating a
# hard-coded path that could drift from it.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKGS="$HERE/install/packages.txt"
KEYWORDS="$HERE/gentoo/package.accept_keywords"
BOOTSTRAP="$HERE/bootstrap.sh"
QUIET=0
REQUIRE_TREE=0
for _arg in "$@"; do
  case "$_arg" in
    --quiet) QUIET=1 ;;
    --require-tree) REQUIRE_TREE=1 ;;
    -h | --help)
      sed -n '2,47p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      printf 'unknown arg: %s (valid: --quiet, --require-tree)\n' "$_arg" >&2
      exit 2
      ;;
  esac
done
unset _arg

say() { ((QUIET)) || printf '%s\n' "$*"; }
err() { printf 'FAIL  %s\n' "$*" >&2; }
warn() { printf 'WARN  %s\n' "$*" >&2; }

# ── locate a tree ─────────────────────────────────────────────────────────────
# portageq is authoritative (it honours a relocated PORTDIR / repos.conf); the
# hard-coded default is the fallback for a box without portage installed at all.
TREE=""
if command -v portageq >/dev/null 2>&1; then
  TREE="$(portageq get_repo_path / gentoo 2>/dev/null || true)"
fi
[[ -n "$TREE" && -d "$TREE" ]] || TREE=/var/db/repos/gentoo
if [[ ! -d "$TREE/app-shells" ]]; then
  if ((REQUIRE_TREE)); then
    err "no synced ::gentoo tree at $TREE, and --require-tree was given — refusing to report success without checking anything"
    exit 1
  fi
  say "no synced ::gentoo tree at $TREE — skipping (run emerge --sync, or emerge-webrsync in CI)"
  exit 0
fi

ARCH=""
if command -v portageq >/dev/null 2>&1; then ARCH="$(portageq envvar ARCH 2>/dev/null || true)"; fi
[[ -n "$ARCH" ]] || ARCH=amd64

# ── locate the GURU overlay ───────────────────────────────────────────────────
# Same precedence as the ::gentoo tree above (an explicit override, then portageq,
# then the conventional path), because a GURU atom is checkable in exactly one
# place and guessing wrong means checks 5 and 6 quietly verify nothing.
# An explicit GURU_TREE is used VERBATIM and never falls back: silently checking
# /var/db/repos/guru when the operator named some other path would validate a
# different tree than the one they asked about, and report the answer as theirs.
GURU=""
if [[ -n "${GURU_TREE:-}" ]]; then
  GURU="$GURU_TREE"
else
  if command -v portageq >/dev/null 2>&1; then
    GURU="$(portageq get_repo_path / guru 2>/dev/null || true)"
  fi
  [[ -n "$GURU" && -d "$GURU" ]] || GURU=/var/db/repos/guru
fi
GURU_OK=1
if [[ ! -d "$GURU/app-misc" ]]; then
  if ((REQUIRE_TREE)); then
    err "no GURU overlay at $GURU, and --require-tree was given — refusing to report success without checking the GURU list"
    exit 1
  fi
  GURU_OK=0
fi

say "tree:  $TREE"
say "arch:  $ARCH"
if ((GURU_OK)); then say "guru:  $GURU"; else say "guru:  (absent — checks 5-6 skipped)"; fi

# ── read the atom list (same stripping rule bootstrap.sh uses) ────────────────
atoms=()
while IFS= read -r line; do
  line="${line%%#*}"
  line="${line//[[:space:]]/}"
  [[ -n "$line" ]] && atoms+=("$line")
done <"$PKGS"
say "atoms: ${#atoms[@]}"

# ── the GURU list, read from the guru_install CALL in bootstrap.sh ─────────────
# Parsed rather than duplicated here on purpose: a second copy of the list is a
# second thing to forget, and it would have agreed with the first that gum was
# fine. This reads the arguments of the actual call — the definition line
# (`guru_install() {`) is excluded by requiring whitespace or a line-end after the
# name, and comments are stripped, so a mention in prose cannot smuggle an atom in.
guru_atoms=()
while IFS= read -r line; do
  [[ -n "$line" ]] && guru_atoms+=("$line")
done < <(awk '
  function emit(s,   n, f, i) {
    sub(/#.*/, "", s)
    n = split(s, f, /[[:space:]]+/)
    for (i = 1; i <= n; i++)
      if (f[i] != "" && f[i] != "\\") print f[i]
  }
  {
    line = $0
    if (!collecting) {
      if (line ~ /^[[:space:]]*guru_install[[:space:]]*\\?[[:space:]]*$/ ||
          line ~ /^[[:space:]]*guru_install[[:space:]]+[^(]/) {
        sub(/^[[:space:]]*guru_install/, "", line)
        collecting = 1
      } else next
    }
    cont = (line ~ /\\[[:space:]]*$/)
    emit(line)
    if (!cont) collecting = 0
  }
' "$BOOTSTRAP")
say "guru atoms: ${#guru_atoms[@]} (from the guru_install call in bootstrap.sh)"

# A parser that finds nothing is indistinguishable from a clean bill of health,
# which is the exact shape of bug this whole script exists to refuse. bootstrap.sh
# HAS a guru_install call; if we cannot see its arguments the parser has drifted
# and must fail loudly rather than pass silently.
if ((${#guru_atoms[@]} == 0)); then
  err "parsed 0 atoms from the guru_install call in $BOOTSTRAP — the parser has drifted from the script (or the call was removed); refusing to pass without checking it"
  exit 1
fi

# ── the keyword list we ship (atom names only; __ARCH__ is rendered at install) ─
keyworded=()
if [[ -r "$KEYWORDS" ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    # shellcheck disable=SC2206  # deliberate word-split: "<atom> <keyword>"
    parts=($line)
    [[ ${#parts[@]} -ge 1 && -n "${parts[0]:-}" ]] && keyworded+=("${parts[0]}")
  done <"$KEYWORDS"
fi

_is_keyworded() {
  local a want="$1"
  for a in ${keyworded[@]+"${keyworded[@]}"}; do [[ "$a" == "$want" ]] && return 0; done
  return 1
}

# _has_stable <atom> — does ANY ebuild carry a stable keyword for this ARCH?
#
# Matches a bare `amd64` but not `~amd64` or `-amd64`: the keyword must be
# preceded by a quote or space and followed by a quote or space, so it cannot
# match inside `~amd64` or `~amd64-linux`.
#
# The KEYWORDS assignment is NOT always at column 0 — plenty of ebuilds set it
# inside a conditional, e.g. app-misc/tmux:
#
#     if [[ ${PV} != 9999 ]]; then
#             KEYWORDS="~alpha amd64 arm arm64 ..."
#
# so this anchors on optional leading whitespace. Anchoring on `^KEYWORDS=` (the
# obvious spelling) silently reported tmux, neovim, git, curl and gawk as having
# no stable keyword — a false alarm on five of the most obviously stable packages
# in the tree, which is how this was caught.
#
# HEURISTIC, deliberately: the authoritative answer is `portageq best_visible`,
# but that reads the LOCAL /etc/portage — including the accept_keywords file this
# repo installs — so on a provisioned box it would confirm itself. Reading the
# ebuilds answers the question that actually matters here: would a FRESH stable
# box, with only what we ship, be able to install this?
_has_stable() {
  local dir="${2:-$TREE}/$1" f
  for f in "$dir"/*.ebuild; do
    [[ -e "$f" ]] || continue
    grep -qE "^[[:space:]]*KEYWORDS=.*[\"' ]${ARCH}([\"' ]|$)" "$f" && return 0
  done
  return 1
}

rc=0
missing=() unstable_uncovered=() stale=()
guru_missing=() guru_uncovered=() guru_graduated=() dead_keys=()

for atom in ${atoms[@]+"${atoms[@]}"}; do
  # 1. shape
  if [[ "$atom" != */* ]]; then
    err "$atom — not a category/name atom (Portage needs the full atom)"
    rc=1
    continue
  fi
  # 2. existence
  if [[ ! -d "$TREE/$atom" ]]; then
    missing+=("$atom")
    rc=1
    continue
  fi
  # 3. reachability on a stable profile
  if ! _has_stable "$atom" && ! _is_keyworded "$atom"; then
    unstable_uncovered+=("$atom")
    rc=1
  fi
done

# 4. staleness — a keyword line whose atom is now stable everywhere it matters.
# Only ::gentoo atoms are checkable; a GURU atom is simply absent from this tree
# and is skipped rather than reported as stale.
for atom in ${keyworded[@]+"${keyworded[@]}"}; do
  [[ -d "$TREE/$atom" ]] || continue
  _has_stable "$atom" && stale+=("$atom")
done

# 5 + 6. The GURU list, and keyword lines that unmask nothing.
#
# Both need the overlay: without it "not in GURU" and "cannot see GURU" are the
# same observation, and reporting the second as the first would invent failures
# on any box that has not synced it. --require-tree has already made an absent
# overlay fatal further up, so reaching here with GURU_OK=0 means the operator
# explicitly accepted a partial check.
if ((GURU_OK)); then
  for atom in ${guru_atoms[@]+"${guru_atoms[@]}"}; do
    if [[ "$atom" != */* ]]; then
      err "$atom — not a category/name atom in the guru_install call"
      rc=1
      continue
    fi
    if [[ -d "$GURU/$atom" ]]; then
      # In GURU, as expected. GURU keywords everything ~arch by policy, so the
      # atom still has to be reachable on a stable profile the same way check 3
      # demands of a packages.txt atom.
      if ! _has_stable "$atom" "$GURU" && ! _is_keyworded "$atom"; then
        guru_uncovered+=("$atom")
        rc=1
      fi
    elif [[ -d "$TREE/$atom" ]]; then
      # Graduated to the main tree. Not broken — but guru_install runs AFTER the
      # main emerge, so leaving it here installs it later than it needs to be.
      guru_graduated+=("$atom")
    else
      guru_missing+=("$atom")
      rc=1
    fi
  done

  # 6. the gum line: a keyword for an atom that exists nowhere unmasks nothing,
  # and reads as proof the atom was considered and handled.
  for atom in ${keyworded[@]+"${keyworded[@]}"}; do
    [[ -d "$TREE/$atom" || -d "$GURU/$atom" ]] && continue
    dead_keys+=("$atom")
    rc=1
  done
fi

((${#missing[@]} == 0)) || {
  err "not in ::gentoo (typo, wrong category, or overlay-only — overlay atoms do not belong in packages.txt):"
  printf '        %s\n' "${missing[@]}" >&2
}
((${#unstable_uncovered[@]} == 0)) || {
  err "no stable keyword for $ARCH and no line in gentoo/package.accept_keywords — a stable profile CANNOT install these:"
  printf '        %s\n' "${unstable_uncovered[@]}" >&2
}
((${#stale[@]} == 0)) || {
  warn "these have gone stable — the accept_keywords line is now dead weight and can be dropped:"
  printf '        %s\n' "${stale[@]}" >&2
}
((${#guru_missing[@]} == 0)) || {
  err "bootstrap.sh emerges these from GURU, but they exist in NEITHER GURU nor ::gentoo — every run skips them (this is the app-misc/gum bug):"
  printf '        %s\n' "${guru_missing[@]}" >&2
}
((${#guru_uncovered[@]} == 0)) || {
  err "in GURU with no stable keyword for $ARCH and no line in gentoo/package.accept_keywords — a stable profile CANNOT install these:"
  printf '        %s\n' "${guru_uncovered[@]}" >&2
}
((${#dead_keys[@]} == 0)) || {
  err "accept_keywords lines for atoms that exist in neither tree — they unmask nothing and hide the real problem:"
  printf '        %s\n' "${dead_keys[@]}" >&2
}
((${#guru_graduated[@]} == 0)) || {
  warn "these are in ::gentoo now — move them from bootstrap.sh's guru_install to install/packages.txt so the main emerge installs them:"
  printf '        %s\n' "${guru_graduated[@]}" >&2
}

if ((rc == 0)); then
  if ((GURU_OK)); then
    say "OK — every atom (packages.txt + the GURU list) exists and is installable on a stable $ARCH profile"
  else
    say "OK — every packages.txt atom exists and is installable on a stable $ARCH profile (GURU absent: the guru_install list was NOT checked)"
  fi
else
  err "packages.txt / accept_keywords need attention (see above)"
fi
exit $rc
