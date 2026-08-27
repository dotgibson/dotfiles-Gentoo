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
#     looks exactly like a keyword mask and is never fixed. Still true, and now
#     sharper: dev-vcs/jj IS packaged and this repo emerges it, so the trap was
#     never "jj is unavailable" — it was the SPELLING.
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
#   7. extras list — every atom bootstrap.sh emerges from its opt-in extras block
#                    (the extras_install call) exists in ::gentoo and is reachable
#                    on a stable profile — the same three checks as 1-3, applied to
#                    a list that also lives in the script. These come from the MAIN
#                    tree, not the overlay, so unlike 5-6 this one always runs.
#   8. floors      — a `# min:X.Y.Z` in install/packages.txt is a CONTRACT: the tree
#                    must be able to give you that version or newer. Reachable is
#                    not the same as USABLE — app-editors/neovim resolves on stable
#                    and installs 0.11.7, one minor under what Core's nvim config
#                    needs, which checks 1-3 cannot see because the atom is stable.
#                    Satisfied either by a stable ebuild at/above the floor, or by a
#                    version-restricted keyword line (`>=atom-x.y.z ~arch`).
#   9. opt-in GURU — the fourth atom list: bootstrap.sh's guru_extras_install call,
#                    which is GURU-sourced AND skipped by --no-extras. Check 5's
#                    questions, applied to a list neither 5 (unconditional) nor 7
#                    (::gentoo) can see.
#
# WHAT NONE OF THESE CAN SEE, and it is worth knowing before you trust a green run:
# check 3 asks "is THIS atom keyworded", never "does it RESOLVE". dev-util/shellcheck
# passed every check here for months while being uninstallable, because its blocker
# was >=dev-haskell/aeson-1.4.0 — a masked DEPENDENCY, one level down. Real
# dependency resolution needs a profile and a working emerge, which is more than this
# script assumes; .github/workflows/packages.yml runs `emerge -p` over the whole set
# in a container to cover it. Keep that step honest, or this blind spot comes back.
#
# Checks 5, 6 and 9 need the GURU overlay. Point GURU_TREE at a checkout, or sync it
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
      # NB a hard-coded range over this file's OWN header: growing the checks
      # list above silently truncates --help mid-sentence, and nothing tests it.
      # The end line is the `GURU_TREE=...` usage line — re-derive it after any
      # edit to the header rather than adjusting it by arithmetic.
      sed -n '2,73p' "${BASH_SOURCE[0]}"
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
    err "no GURU overlay at $GURU, and --require-tree was given — refusing to report success without checking the GURU lists"
    exit 1
  fi
  GURU_OK=0
fi

say "tree:  $TREE"
say "arch:  $ARCH"
if ((GURU_OK)); then say "guru:  $GURU"; else say "guru:  (absent — checks 5-6 and 9 skipped)"; fi

# ── read the atom list (same stripping rule bootstrap.sh uses) ────────────────
atoms=()
while IFS= read -r line; do
  line="${line%%#*}"
  line="${line//[[:space:]]/}"
  [[ -n "$line" ]] && atoms+=("$line")
done <"$PKGS"
say "atoms: ${#atoms[@]}"

# ── the atom lists bootstrap.sh hard-codes, read from the CALLS themselves ─────
# Parsed rather than duplicated here on purpose: a second copy of a list is a
# second thing to forget, and it would have agreed with the first that gum was
# fine. This reads the arguments of the actual call — a definition line
# (`guru_install() {`) is excluded by requiring whitespace or a line-end after the
# name, and comments are stripped, so a mention in prose cannot smuggle an atom in.
#
# Parameterised by callee name because there are now three such lists: guru_install
# (checks 5-6), extras_install (check 7) and guru_extras_install (check 9). The
# regexes are built as strings in BEGIN so the name can vary; "\\\\" is one literal
# backslash in a dynamic regex.
#
# The three names are safe to parse independently even though two share a substring:
# every regex anchors at ^[[:space:]]*<name>, so a `guru_extras_install app-arch/ouch`
# line cannot be read by the `extras_install` parser (the line does not START with
# it) nor by the `guru_install` one (`guru_e` != `guru_i`).
_atoms_from_call() { # <function-name>
  awk -v fn="$1" '
    BEGIN {
      re_alone = "^[[:space:]]*" fn "[[:space:]]*\\\\?[[:space:]]*$"
      re_args  = "^[[:space:]]*" fn "[[:space:]]+[^(]"
      re_strip = "^[[:space:]]*" fn
    }
    function emit(s,   n, f, i) {
      sub(/#.*/, "", s)
      n = split(s, f, /[[:space:]]+/)
      for (i = 1; i <= n; i++)
        if (f[i] != "" && f[i] != "\\") print f[i]
    }
    {
      line = $0
      if (!collecting) {
        if (line ~ re_alone || line ~ re_args) {
          sub(re_strip, "", line)
          collecting = 1
        } else next
      }
      cont = (line ~ /\\[[:space:]]*$/)
      emit(line)
      if (!cont) collecting = 0
    }
  ' "$BOOTSTRAP"
}

# A parser that finds nothing is indistinguishable from a clean bill of health,
# which is the exact shape of bug this whole script exists to refuse. bootstrap.sh
# HAS both calls; if we cannot see the arguments of one, the parser has drifted
# and must fail loudly rather than pass silently. NB this makes "the call exists,
# with at least one atom" a contract: if the last atom is ever removed from one of
# these lists, delete its call site AND its guard here, in the same commit.
_require_atoms() { # <count> <function-name>
  (($1)) && return 0
  err "parsed 0 atoms from the $2 call in $BOOTSTRAP — the parser has drifted from the script (or the call was removed); refusing to pass without checking it"
  exit 1
}

guru_atoms=()
while IFS= read -r line; do
  [[ -n "$line" ]] && guru_atoms+=("$line")
done < <(_atoms_from_call guru_install)
say "guru atoms: ${#guru_atoms[@]} (from the guru_install call in bootstrap.sh)"
_require_atoms "${#guru_atoms[@]}" guru_install

extras_atoms=()
while IFS= read -r line; do
  [[ -n "$line" ]] && extras_atoms+=("$line")
done < <(_atoms_from_call extras_install)
say "extras atoms: ${#extras_atoms[@]} (from the extras_install call in bootstrap.sh)"
_require_atoms "${#extras_atoms[@]}" extras_install

guru_extras_atoms=()
while IFS= read -r line; do
  [[ -n "$line" ]] && guru_extras_atoms+=("$line")
done < <(_atoms_from_call guru_extras_install)
say "opt-in guru atoms: ${#guru_extras_atoms[@]} (from the guru_extras_install call in bootstrap.sh)"
_require_atoms "${#guru_extras_atoms[@]}" guru_extras_install

# ── the keyword list we ship (atom names only; __ARCH__ is rendered at install) ─
# A line is EITHER a bare atom (`app-shells/zoxide ~arch` — the atom has no stable
# ebuild and cannot install at all) or version-restricted (`>=app-editors/neovim-
# 0.12.0 ~arch` — the atom installs fine on stable, but below a floor Core needs).
# Both spellings are Portage-valid and they mean different things, so both are kept:
#
#   keyworded[]      bare atom, for the existence and coverage lookups (checks 3, 6)
#   keyword_floor[]  atom -> the floor a `>=` line unmasks, for check 8. A bare line
#                    records no floor, so it can never satisfy one.
#
# Without the operator strip, `>=app-editors/neovim-0.12.0` reaches check 6 as an
# atom name, is not a directory in either tree, and gets reported as a line that
# "unmasks nothing" — fatal, on a line that unmasks precisely what it says.
keyworded=()
declare -A keyword_floor=()
declare -A keyword_versioned=()
if [[ -r "$KEYWORDS" ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    # shellcheck disable=SC2206  # deliberate word-split: "<atom> <keyword>"
    parts=($line)
    [[ ${#parts[@]} -ge 1 && -n "${parts[0]:-}" ]] || continue
    spec="${parts[0]}"
    atom="$spec"
    # Range operators Portage accepts on an accept_keywords line. `=` and `~` are
    # exact/that-version-any-revision rather than floors, so they are stripped for
    # the lookups but record no floor: only >= (and >) raise a minimum.
    if [[ "$spec" =~ ^(\>=|\>|\<=|\<|=|~)(.+)$ ]]; then
      op="${BASH_REMATCH[1]}"
      atom="${BASH_REMATCH[2]}"
      # Strip the -rN revision, then the trailing -<version>: a version starts at
      # the last `-` followed by a digit, which is exactly Portage's own rule for
      # splitting P into PN and PV, and PVR is PV plus an optional -rN. The revision
      # has to come off FIRST or the rule declines to split at all — in
      # `>=dev-foo/bar-1.2.3-r2` the last `-` is followed by `r`. No line here
      # carries one today; bootstrap.sh's _atom_of parses arbitrary emerge output
      # where they are common, and the two are meant to agree.
      rev="${atom##*-}"
      if [[ "$atom" == *-* && "$rev" =~ ^r[0-9]+$ ]]; then atom="${atom%-*}"; fi
      ver="${atom##*-}"
      if [[ "$atom" == *-* && "$ver" =~ ^[0-9] ]]; then
        atom="${atom%-*}"
        [[ "$op" == ">=" || "$op" == ">" ]] && keyword_floor["$atom"]="$ver"
      fi
      keyword_versioned["$atom"]=1
    fi
    keyworded+=("$atom")
  done <"$KEYWORDS"
fi

# Was THIS atom's keyword line version-restricted? Check 4 needs to know: a `>=`
# line exists BECAUSE a stable version below the floor exists, so "it has gone
# stable, the line is dead weight" is exactly backwards there.
_is_versioned_keyword() { [[ -n "${keyword_versioned[$1]:-}" ]]; }

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
# The KEYWORDS grep itself, so that _has_stable and _ebuild_versions cannot drift
# apart on the one expression the paragraph above is entirely about.
_ebuild_is_stable() { # <ebuild-path>
  grep -qE "^[[:space:]]*KEYWORDS=.*[\"' ]${ARCH}([\"' ]|$)" "$1"
}

_has_stable() {
  local dir="${2:-$TREE}/$1" f
  for f in "$dir"/*.ebuild; do
    [[ -e "$f" ]] || continue
    _ebuild_is_stable "$f" && return 0
  done
  return 1
}

# _ebuild_versions <atom> [--stable] — every PV this atom has in the tree, one per
# line. `9999` (and any other live ebuild) is excluded: it sorts above everything
# and is not a version anyone gets by asking for the atom.
#
# The PN/PV split is Portage's own rule read backwards — the filename is
# `<pn>-<pv>.ebuild` and pn is the atom's own name, so there is nothing to guess.
_ebuild_versions() { # <atom> [--stable]
  local atom="$1" pn="${1##*/}" only_stable="${2:-}" f v
  for f in "$TREE/$atom"/*.ebuild; do
    [[ -e "$f" ]] || continue
    if [[ "$only_stable" == "--stable" ]]; then
      _ebuild_is_stable "$f" || continue
    fi
    v="${f##*/}"
    v="${v%.ebuild}"
    v="${v#"$pn"-}"
    [[ "$v" == 9999* ]] && continue
    printf '%s\n' "$v"
  done
}

# _ver_ge <a> <b> — is a >= b?
#
# HEURISTIC, and deliberately so, for the same reason _has_stable is: the
# authoritative answer is Portage's own version algebra, which needs Portage. This
# is `sort -V`, which agrees with it on plain dotted versions and on `-rN`
# revisions — everything this repo's floors are written in. It does NOT understand
# Gentoo's `_alpha/_beta/_rc/_p` suffixes, which sort as ordinary text; a floor
# written with one would compare wrong. Don't write one, or teach this function
# first. Floors are ours to choose, so this is a constraint, not a gap.
_ver_ge() { # <a> <b>
  [[ "$1" == "$2" ]] && return 0
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]
}

# ── the `# min:` floors declared in install/packages.txt ───────────────────────
# Read in a SECOND pass: the atom loop above strips comments before anything can
# see them, and the floor lives in the comment. Same contract spelling as
# dotfiles-Debian's packages.txt, which is where this convention comes from.
declare -A floors=()
while IFS= read -r line; do
  [[ "$line" == *#* ]] || continue
  floor_atom="${line%%#*}"
  floor_atom="${floor_atom//[[:space:]]/}"
  [[ -n "$floor_atom" ]] || continue
  floor_cmt=" ${line#*#}"
  [[ "$floor_cmt" =~ [[:space:]]min:([^[:space:]]+) ]] || continue
  floors["$floor_atom"]="${BASH_REMATCH[1]}"
done <"$PKGS"
unset floor_atom floor_cmt
say "floors: ${#floors[@]} (\`# min:\` contracts in $(basename "$PKGS"))"

rc=0
missing=() unstable_uncovered=() stale=()
guru_missing=() guru_uncovered=() guru_graduated=() dead_keys=()
guru_extras_missing=() guru_extras_uncovered=() guru_extras_graduated=()
extras_missing=() extras_uncovered=()
floor_unsat=() floor_uncovered=()

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
  # A version-restricted line is about specific versions, not the atom as a whole.
  # Its atom having SOME stable ebuild is the premise of the line, not evidence
  # against it — reporting it here would tell you to delete the floor. Check 8 is
  # what says whether that line is still needed.
  _is_versioned_keyword "$atom" && continue
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

  # 9. The opt-in GURU list. Check 5's three questions over a different call, kept
  # as its own loop so the messages can name where the atom came from — "move it to
  # packages.txt" is wrong advice for an atom that --no-extras must be able to skip.
  for atom in ${guru_extras_atoms[@]+"${guru_extras_atoms[@]}"}; do
    if [[ "$atom" != */* ]]; then
      err "$atom — not a category/name atom in the guru_extras_install call"
      rc=1
      continue
    fi
    if [[ -d "$GURU/$atom" ]]; then
      if ! _has_stable "$atom" "$GURU" && ! _is_keyworded "$atom"; then
        guru_extras_uncovered+=("$atom")
        rc=1
      fi
    elif [[ -d "$TREE/$atom" ]]; then
      # Graduated. Advisory, and the advice differs from check 5's: this atom is
      # opt-in, so it belongs in the extras_install call, NOT in packages.txt.
      guru_extras_graduated+=("$atom")
    else
      guru_extras_missing+=("$atom")
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

# 7. The opt-in extras block. Same three questions as checks 1-3 — these atoms
# come from ::gentoo, not the overlay — so this is NOT inside the GURU_OK gate
# above: it needs nothing the packages.txt loop did not already have. It is a
# separate loop rather than atoms appended to that one so the messages can name
# where the atom came from; "overlay atoms do not belong in packages.txt" would be
# actively wrong advice for an atom that is not in packages.txt at all.
for atom in ${extras_atoms[@]+"${extras_atoms[@]}"}; do
  if [[ "$atom" != */* ]]; then
    err "$atom — not a category/name atom in the extras_install call"
    rc=1
    continue
  fi
  if [[ ! -d "$TREE/$atom" ]]; then
    extras_missing+=("$atom")
    rc=1
    continue
  fi
  if ! _has_stable "$atom" && ! _is_keyworded "$atom"; then
    extras_uncovered+=("$atom")
    rc=1
  fi
done

# 8. Version floors. The question checks 1-3 cannot ask: not "can this install?"
# but "can this install a version Core can actually use?". app-editors/neovim is
# the case that motivated it — stable, reachable, and 0.11.7, one minor under what
# nvim-treesitter's `main` branch hard-requires. Every check above passed on it.
if ((${#floors[@]})); then
  while IFS= read -r atom; do
    want="${floors[$atom]}"
    # Not in the tree at all is check 2's finding, already fatal. Reporting it a
    # second time as a floor failure would double-count one problem.
    [[ -d "$TREE/$atom" ]] || continue

    best="$(_ebuild_versions "$atom" | sort -V | tail -n1)"
    if [[ -z "$best" ]] || ! _ver_ge "$best" "$want"; then
      # No ebuild reaches the floor at ALL. No keyword line can fix this; the tree
      # simply does not carry a usable version. This is the Debian-lane trap
      # arriving on Gentoo, and it is why the floor is checked rather than trusted.
      floor_unsat+=("$atom — needs >= $want, newest in ::gentoo is ${best:-none}")
      rc=1
      continue
    fi

    # Satisfied by stable? Then no keyword line is wanted, and one would be dead
    # weight (check 4's job to say so).
    best_stable="$(_ebuild_versions "$atom" --stable | sort -V | tail -n1)"
    [[ -n "$best_stable" ]] && _ver_ge "$best_stable" "$want" && continue

    # Otherwise the floor has to come from a version-restricted keyword line whose
    # own floor is at least as high. A BARE keyword line does not count: it unmasks
    # every testing version including ones below the floor, so it cannot promise
    # what the floor asks for.
    kf="${keyword_floor[$atom]:-}"
    [[ -n "$kf" ]] && _ver_ge "$kf" "$want" && continue

    if [[ -n "$kf" ]]; then
      floor_uncovered+=("$atom — needs >= $want; newest STABLE is ${best_stable:-none}, and the keyword line only unmasks >= $kf")
    else
      floor_uncovered+=("$atom — needs >= $want; newest STABLE is ${best_stable:-none}, and $(basename "$KEYWORDS") has no \">=$atom-$want ~$ARCH\" line")
    fi
    rc=1
  done < <(printf '%s\n' "${!floors[@]}" | sort)
fi

((${#missing[@]} == 0)) || {
  err "not in ::gentoo (typo, wrong category, or overlay-only — overlay atoms do not belong in packages.txt):"
  printf '        %s\n' "${missing[@]}" >&2
}
((${#unstable_uncovered[@]} == 0)) || {
  err "no stable keyword for $ARCH and no line in gentoo/package.accept_keywords — a stable profile CANNOT install these:"
  printf '        %s\n' "${unstable_uncovered[@]}" >&2
}
((${#extras_missing[@]} == 0)) || {
  err "bootstrap.sh's opt-in extras block emerges these, but they are not in ::gentoo — a GURU-only atom belongs in the guru_install call instead, and an atom in neither tree is the app-misc/gum bug again:"
  printf '        %s\n' "${extras_missing[@]}" >&2
}
((${#extras_uncovered[@]} == 0)) || {
  err "emerged by bootstrap.sh's opt-in extras block with no stable keyword for $ARCH and no line in gentoo/package.accept_keywords — a stable profile CANNOT install these:"
  printf '        %s\n' "${extras_uncovered[@]}" >&2
}
((${#floor_unsat[@]} == 0)) || {
  err "declared a \`# min:\` floor that ::gentoo CANNOT satisfy at any keyword — the atom resolves, but every version in the tree is below what Core needs:"
  printf '        %s\n' "${floor_unsat[@]}" >&2
}
((${#floor_uncovered[@]} == 0)) || {
  err "declared a \`# min:\` floor that a stable profile does not reach — the emerge SUCCEEDS and installs a version below the floor, which no other check here can see:"
  printf '        %s\n' "${floor_uncovered[@]}" >&2
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
((${#guru_extras_missing[@]} == 0)) || {
  err "bootstrap.sh's opt-in extras block emerges these from GURU, but they exist in NEITHER GURU nor ::gentoo — every run skips them (this is the app-misc/gum bug):"
  printf '        %s\n' "${guru_extras_missing[@]}" >&2
}
((${#guru_extras_uncovered[@]} == 0)) || {
  err "emerged from GURU by bootstrap.sh's opt-in extras block with no stable keyword for $ARCH and no line in gentoo/package.accept_keywords — a stable profile CANNOT install these:"
  printf '        %s\n' "${guru_extras_uncovered[@]}" >&2
}
((${#guru_graduated[@]} == 0)) || {
  warn "these are in ::gentoo now — move them from bootstrap.sh's guru_install to install/packages.txt so the main emerge installs them:"
  printf '        %s\n' "${guru_graduated[@]}" >&2
}
((${#guru_extras_graduated[@]} == 0)) || {
  warn "these are in ::gentoo now — move them from bootstrap.sh's guru_extras_install to the extras_install call (NOT to packages.txt: they are opt-in, and packages.txt is the unconditional emerge):"
  printf '        %s\n' "${guru_extras_graduated[@]}" >&2
}

if ((rc == 0)); then
  if ((GURU_OK)); then
    say "OK — every atom (packages.txt + both extras lists + the GURU list) exists, is installable on a stable $ARCH profile, and meets every declared \`# min:\` floor"
  else
    say "OK — every packages.txt and ::gentoo extras-block atom exists, is installable on a stable $ARCH profile, and meets every declared \`# min:\` floor (GURU absent: the guru_install and guru_extras_install lists were NOT checked)"
  fi
else
  err "packages.txt / accept_keywords need attention (see above)"
fi
exit $rc
