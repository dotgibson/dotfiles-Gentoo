#!/usr/bin/env bash
# dotfiles-Gentoo/scripts/assert-provisioned.sh
# ──────────────────────────────────────────────────────────────────────────────
# THE FAR-SIDE ASSERTION: after a real bootstrap, is the tool actually there?
#
# WHY THIS EXISTS. bootstrap.sh ends with an honest ledger of every best-effort step
# that did not complete — and then exits 0 anyway, because --strict is off by
# default. That default is a decision, not an oversight (bootstrap.sh's usage()
# spells out the reasoning), but it left nothing consuming the ledger: the first
# weekly unstubbed sweep ever to run to completion went GREEN while reporting that
# the box had shipped without shellcheck and without ouch. "Fully provisioned" and
# "provisioned except two tools" were the same colour (issue #133).
#
# --strict is the wrong instrument for that. It fires on the whole ledger, and the
# ledger deliberately mixes a genuine provisioning gap (an atom that will never
# install here) with an infrastructure blip (a rate-limited mise.run, a GURU sync
# hiccup, a failed tpm clone). A gate that goes red for somebody else's outage is one
# everybody learns to ignore. dotfiles-Fedora's bootstrap-full.yml reached the same
# conclusion and asserts PRESENCE instead; this is that, for Gentoo.
#
# THE SPLIT, and it is the whole design:
#
#   HARD-FAIL   every atom in install/packages.txt. That file is the UNCONDITIONAL
#               emerge — if one of those is not on PATH afterwards, the box is not
#               provisioned, full stop.
#   WARN        the GURU overlay tools, the cargo/go builds, and the opt-in extras.
#               None of these are promised by a run: --no-extras skips some, GURU may
#               not be enabled, and an upstream crate may be broken today.
#
# THE HARD-FAIL LIST IS DERIVED, NEVER COPIED. It is read out of install/packages.txt
# via the `# bin:NAME` contract (defaulting to the atom's own name), for the reason
# scripts/check-packages.sh states in its own header: a second copy of a list is a
# second thing to forget, and it is precisely how app-misc/gum survived for months.
# The warn list is derived the same way from bootstrap.sh's own calls — only a
# handful of NAME OVERRIDES are written down here, and getting one of those wrong
# costs a spurious warning, never a false pass and never a false failure.
#
# Usage:
#   ./scripts/assert-provisioned.sh              # assert; non-zero if a required tool is missing
#   ./scripts/assert-provisioned.sh --quiet      # only report problems
#   ./scripts/assert-provisioned.sh --no-extras  # the box was bootstrapped with --no-extras:
#                                                #   drop the opt-in tools from the report entirely
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKGS="$HERE/install/packages.txt"
BOOTSTRAP="$HERE/bootstrap.sh"
QUIET=0
NO_EXTRAS=0
for _arg in "$@"; do
  case "$_arg" in
    --quiet) QUIET=1 ;;
    --no-extras) NO_EXTRAS=1 ;;
    -h | --help)
      # NB a hard-coded range over this file's OWN header — growing it truncates
      # --help mid-sentence, and nothing tests that. Re-derive after any edit.
      sed -n '2,42p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      printf 'unknown arg: %s (valid: --quiet, --no-extras)\n' "$_arg" >&2
      exit 2
      ;;
  esac
done
unset _arg

say() { ((QUIET)) || printf '%s\n' "$*"; }
err() { printf 'FAIL  %s\n' "$*" >&2; }
warn() { printf 'WARN  %s\n' "$*" >&2; }

# The per-user bindirs the language installers write into. cargo writes
# ~/.cargo/bin and go is pointed at ~/.local/bin by bootstrap.sh; neither is on a
# bare login PATH (they reach it through the Core zsh layer, which this script is
# not running inside). Without this, every cargo/go tool reads as missing on a box
# where it installed perfectly — the same guard bug bootstrap.sh fixes with
# blib_user_bindirs_on_path, arriving one script over.
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims:$PATH"

[[ -r "$PKGS" ]] || {
  err "install/packages.txt is missing or unreadable ($PKGS) — this is a broken checkout, not an empty package set"
  exit 1
}

# ── the REQUIRED set: install/packages.txt, via the `# bin:` contract ──────────
# Read in one pass over the raw lines, because the atom is left of the `#` and the
# contract is right of it. `# bin:-` means the atom installs no user-facing
# executable (a Python module, an eselect module) and is skipped.
required=()
required_atom=()
while IFS= read -r line; do
  atom="${line%%#*}"
  atom="${atom//[[:space:]]/}"
  [[ -n "$atom" ]] || continue
  bin="${atom##*/}"
  if [[ "$line" == *#* ]]; then
    cmt=" ${line#*#}"
    [[ "$cmt" =~ [[:space:]]bin:([^[:space:]]+) ]] && bin="${BASH_REMATCH[1]}"
  fi
  [[ "$bin" == "-" ]] && continue
  required+=("$bin")
  required_atom+=("$atom")
done <"$PKGS"

# A parser that finds nothing is indistinguishable from a clean bill of health —
# the exact shape of bug this script exists to refuse.
((${#required[@]})) || {
  err "parsed 0 required binaries from $PKGS — the \`# bin:\` parser has drifted from the file; refusing to report success without checking anything"
  exit 1
}

# ── the BEST-EFFORT set: read out of bootstrap.sh's own calls ─────────────────
# Atoms from the three hard-coded lists, plus the cargo/go tools — whose binary
# name is literally the second argument of the call, so nothing needs mapping there.
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
        if (line ~ re_alone || line ~ re_args) { sub(re_strip, "", line); collecting = 1 }
        else next
      }
      cont = (line ~ /\\[[:space:]]*$/)
      emit(line)
      if (!cont) collecting = 0
    }
  ' "$BOOTSTRAP"
}

# The only hand-written mapping in this file, and deliberately the smallest one: an
# atom whose executable is not its own name. A new GURU atom needs no edit here — it
# defaults to its PN and, being warn-only, a wrong default costs one noisy line.
# Keys are QUOTED. Unquoted, `shfmt` parses [app-misc/1password-cli] as an
# arithmetic subscript and `make fmt` rewrites it to `[app - misc / 1password - cli]`,
# silently breaking the map. check-packages.sh quotes its subscripts for the same
# reason; keep it that way.
declare -A BIN_OVERRIDE=(
  ["app-misc/1password-cli"]=op
  ["app-misc/tealdeer"]=tldr
)

besteffort=()
_add_best() { # <binary>
  local b="$1" existing
  for existing in ${besteffort[@]+"${besteffort[@]}"}; do
    [[ "$existing" == "$b" ]] && return 0
  done
  besteffort+=("$b")
}

_add_atoms_as_best() { # <function-name>
  local atom
  while IFS= read -r atom; do
    [[ -n "$atom" ]] || continue
    _add_best "${BIN_OVERRIDE[$atom]:-${atom##*/}}"
  done < <(_atoms_from_call "$1")
}

_add_atoms_as_best guru_install
if ((NO_EXTRAS == 0)); then
  _add_atoms_as_best extras_install
  _add_atoms_as_best guru_extras_install
fi

# The cargo/go calls: `_dotfiles_cargo_install <crate> <binary>`. Second argument,
# straight from the call — the one list in this script that cannot drift at all.
# The definition lines are excluded because their $1 carries the `()`.
while IFS= read -r b; do
  [[ -n "$b" ]] && _add_best "$b"
done < <(awk '$1 ~ /^_dotfiles_(cargo|go)_install$/ && NF >= 3 { print $3 }' "$BOOTSTRAP" | sort -u)

# mise installs itself from its own installer, not from an atom, so no list above
# carries it — and most of user mode depends on it.
_add_best mise

say "required: ${#required[@]} (install/packages.txt)"
say "best-effort: ${#besteffort[@]} (bootstrap.sh's GURU / extras / cargo / go calls)"
((NO_EXTRAS)) && say "--no-extras: the opt-in tools are excluded from the report"

rc=0
missing=()
for i in "${!required[@]}"; do
  command -v "${required[$i]}" >/dev/null 2>&1 ||
    missing+=("${required[$i]} (from ${required_atom[$i]})")
done

absent=()
for b in ${besteffort[@]+"${besteffort[@]}"}; do
  command -v "$b" >/dev/null 2>&1 || absent+=("$b")
done

((${#missing[@]} == 0)) || {
  rc=1
  err "emerged from install/packages.txt, but NOT on PATH — this box is not provisioned:"
  printf '        %s\n' "${missing[@]}" >&2
  err "re-read the bootstrap ledger: every one of these should have a line explaining why it did not install"
}
((${#absent[@]} == 0)) || {
  warn "best-effort tools absent (each is HAVE_*-gated in Core, so this costs a ✗ in \`core doctor\` and nothing else):"
  printf '        %s\n' "${absent[@]}" >&2
}

if ((rc == 0)); then
  say "OK — every atom in install/packages.txt put its binary on PATH (${#absent[@]} best-effort tool(s) absent)"
else
  err "the box is missing $((${#missing[@]})) required tool(s) (see above)"
fi
exit $rc
