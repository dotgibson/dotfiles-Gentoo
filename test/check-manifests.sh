#!/usr/bin/env bash
# dotfiles-Gentoo/test/check-manifests.sh
# ──────────────────────────────────────────────────────────────────────────────
# The manifest invariants that are true on ANY host — asserted on any host.
#
# WHY THIS EXISTS, and it is not "a second check-packages.sh". scripts/check-packages.sh
# is the better check, and it is the one CI should trust about Portage. But it opens
# with a tree probe and, finding none, exits 0 having asked NOTHING:
#
#     if [[ ! -d "$TREE/app-shells" ]]; then ... exit 0
#
# That is the right default for a laptop that has never synced — and it means the
# checks in that script which need no tree at all (is this even shaped like an atom?)
# are also skipped there. .github/workflows/packages.yml covers the tree-dependent half
# properly, in a container, with `--require-tree` and `emerge -p`; but it is PATH-FILTERED
# and advisory by deliberate design (its own header explains the trade), so a PR that
# does not touch install/packages.txt gets no manifest signal whatsoever.
#
# So this asks only the questions whose answer does not depend on a Portage tree, an
# ARCH, a profile or a network — which makes it cheap enough to run unfiltered on every
# PR, on a plain runner, in under a second. Every check below is a rule this repo
# already states in prose in the file it governs, enforced by nothing until now.
#
# It reads. It never installs, syncs, emerges, or writes.
#
# THE CHECKS:
#   1. shape        — every install/packages.txt entry is a bare `category/name`: no
#                     version, operator, slot or USE dep. bootstrap.sh feeds these
#                     straight to emerge, and check-packages.sh check 1 asks the same
#                     thing — where a tree exists. This asks it where one does not.
#   2. one home     — no atom appears twice in packages.txt, and no atom appears in
#                     BOTH packages.txt and one of bootstrap.sh's hard-coded lists (or
#                     in two of those lists). packages.txt is the UNCONDITIONAL emerge;
#                     the extras lists are what `--no-extras` promises not to install,
#                     so an atom in both makes that flag a lie. check-packages.sh reads
#                     all four lists and never compares them to each other.
#   3. bin:         — every `# bin:NAME` contract yields a usable command name. It is
#                     read by scripts/assert-provisioned.sh, which is the far-side
#                     assertion of the weekly unstubbed bootstrap — the one gate that
#                     can tell a provisioned box from a half-provisioned one (issue
#                     #133). Its parser takes `[[:space:]]bin:([^[:space:]]+)`, so a
#                     `# bin: nvim` or a `# binary:nvim` does not fail, it VANISHES:
#                     the atom silently falls back to asserting its own basename.
#   4. min:         — same shape of contract, same shape of failure. A `# min:X.Y.Z`
#                     is read by check-packages.sh check 8 with the same anchored
#                     regex, so `# min: 0.12.0` declares a floor that no check reads
#                     and every check reports as met. packages.txt says as much of
#                     itself: "a CONTRACT, not prose".
#   5. __ARCH__     — every gentoo/package.accept_keywords line is `<atom> <keyword>`
#                     and its keyword goes through the __ARCH__ placeholder.
#                     bootstrap.sh renders it from `portageq envvar ARCH` precisely so
#                     the file is correct off amd64; a hard-coded `~amd64` line
#                     installs cleanly and unmasks nothing on an arm64 box — the
#                     silent no-op that _portage_conf_install's own header warns is
#                     "worse than none".
#   6. no blanket   — no `*/*` line in package.accept_keywords. That file's header says
#                     "there should never be one"; this is that sentence, executable.
#
# Exit codes:
#   0  every invariant holds
#   1  a manifest is missing or unreadable — an environment failure, not drift
#   2  one or more invariants are broken (the drift signal)
#
# Usage:
#   test/check-manifests.sh           # from anywhere; it locates the repo itself
#   make test
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# `set -e` is deliberately off (the exit code IS the result), so the cd is guarded by
# hand: continuing from the wrong directory would read some other repo's manifests and
# report the answer as this one's.
cd -- "$REPO_ROOT" || exit 1

PKGS=install/packages.txt
KEYWORDS=gentoo/package.accept_keywords
LICENSE=gentoo/package.license
BOOTSTRAP=bootstrap.sh

# Core's palette when the subtree is vendored, plain text when it is not — this suite
# must run in a bare checkout too.
if [[ -r core/lib/ux.sh ]]; then
  # shellcheck source=core/lib/ux.sh
  source core/lib/ux.sh
fi
say() { printf '%s::%s %s\n' "${UX_BLU:-}" "${UX_RST:-}" "$*"; }
ok() { printf '%s%s%s %s\n' "${UX_GRN:-}" "${UX_OK:-+}" "${UX_RST:-}" "$*"; }
bad() { printf '%s%s%s %s\n' "${UX_RED:-}" "${UX_ERR:-x}" "${UX_RST:-}" "$*" >&2; }

for f in "$PKGS" "$KEYWORDS" "$LICENSE" "$BOOTSTRAP"; do
  [[ -r "$f" ]] || { bad "not readable: $f (is this a dotfiles-Gentoo checkout?)"; exit 1; }
done

fails=()
note() { fails+=("$1"); }

# ── the atom lists ────────────────────────────────────────────────────────────
# packages.txt with bootstrap.sh's OWN stripping rule (comment, then all whitespace),
# so this reads exactly the strings emerge would be handed.
pkgs=()
while IFS= read -r line; do
  atom="${line%%#*}"
  atom="${atom//[[:space:]]/}"
  [[ -n "$atom" ]] && pkgs+=("$atom")
done <"$PKGS"

# A parser that finds nothing is indistinguishable from a clean bill of health — the
# same refusal assert-provisioned.sh and check-packages.sh both make of themselves.
((${#pkgs[@]})) || { bad "parsed 0 atoms from $PKGS — the parser has drifted from the file; refusing to report success without checking anything"; exit 1; }
say "$PKGS — ${#pkgs[@]} atoms"

# The three lists bootstrap.sh hard-codes, read from the CALLS rather than retyped here.
# Same rule check-packages.sh follows and for the same reason: a second copy of a list
# is a second thing to forget, and it would agree with the first that a stale atom is
# fine. Every pattern anchors at ^<name>, so `guru_extras_install app-arch/ouch` is
# read by neither the `extras_install` nor the `guru_install` pass.
_atoms_from_call() { # <function-name> → its atom arguments, one per line
  awk -v fn="$1" '
    BEGIN {
      re_alone = "^[[:space:]]*" fn "[[:space:]]*\\\\?[[:space:]]*$"
      re_args  = "^[[:space:]]*" fn "[[:space:]]+[^(]"
    }
    function emit(s,   n, f, i) {
      sub(/#.*/, "", s); gsub(/\\$/, "", s)
      n = split(s, f, /[[:space:]]+/)
      for (i = 1; i <= n; i++) if (f[i] ~ /^[a-z0-9]+(-[a-z0-9]+)*\//) print f[i]
    }
    # A bare `name \` opens a continued argument list: the atoms are on the lines
    # after it, until one does not end in a backslash.
    $0 ~ re_alone { cont = 1; next }
    cont { emit($0); if ($0 !~ /\\[[:space:]]*$/) cont = 0; next }
    $0 ~ re_args { s = $0; sub("^[[:space:]]*" fn, "", s); emit(s); if ($0 ~ /\\[[:space:]]*$/) cont = 1; next }
  ' "$BOOTSTRAP"
}

declare -A origin=()   # atom → the list(s) that ask for it
add_origin() { # <atom> <list-name>
  if [[ -n "${origin[$1]:-}" ]]; then
    origin["$1"]="${origin[$1]}, $2"
  else
    origin["$1"]="$2"
  fi
}
for a in "${pkgs[@]}"; do add_origin "$a" "$PKGS"; done
for fn in guru_install extras_install guru_extras_install; do
  n=0
  while IFS= read -r a; do
    [[ -n "$a" ]] || continue
    add_origin "$a" "bootstrap.sh:$fn"
    n=$((n + 1))
  done < <(_atoms_from_call "$fn")
  say "bootstrap.sh $fn — $n atoms"
done

# ── 1. shape ──────────────────────────────────────────────────────────────────
# `category/name`, and nothing else. An operator, a version, a `:slot` or a `[use]`
# is a legal Portage atom SPEC but not a legal entry here: bootstrap.sh's emerge takes
# these bare, and the version pins live in gentoo/package.accept_keywords where they
# can be reasoned about per-arch.
for a in "${pkgs[@]}"; do
  case "$a" in
  *:* | *'['* | *'!'* | '>'* | '<'* | '='* | '~'*)
    note "shape: $a carries an operator, slot or USE dep — packages.txt entries are bare category/name (pin versions in $KEYWORDS instead)"
    continue
    ;;
  esac
  if [[ ! "$a" =~ ^[a-z0-9]+(-[a-z0-9]+)*/[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
    note "shape: $a is not a category/name atom — a bare name emerges ambiguously, and a typo'd category emerges as a 'skipped:' line that reads like a keyword mask"
  fi
done

# ── 2. one home per atom ──────────────────────────────────────────────────────
for a in "${!origin[@]}"; do
  [[ "${origin[$a]}" == *,* ]] || continue
  note "duplicate: $a is asked for by ${origin[$a]} — packages.txt is the unconditional emerge and the extras lists are what --no-extras skips, so an atom in both makes that flag a lie"
done

# ── 3 + 4. the `# bin:` and `# min:` contracts ────────────────────────────────
# Both are read with an ANCHORED regex (`[[:space:]]bin:([^[:space:]]+)`) by the script
# that depends on them, so a near-miss spelling does not fail — it silently declares
# nothing. This is the only check in the repo that can see the near-miss, because the
# consumers cannot: to them the line simply has no contract on it.
#
# The consumers prepend a space to the comment before matching, so `#bin:nvim` (no
# space after the `#`) parses fine and is not flagged; `# bin: nvim` and `# binary:nvim`
# do not, and are.
bins=0
mins=0
lineno=0
while IFS= read -r line; do
  lineno=$((lineno + 1))
  atom="${line%%#*}"
  atom="${atom//[[:space:]]/}"
  [[ -n "$atom" ]] || continue
  [[ "$line" == *#* ]] || continue
  cmt=" ${line#*#}"

  if [[ "$cmt" =~ [[:space:]]bin:([^[:space:]]+) ]]; then
    bin="${BASH_REMATCH[1]}"
    # `bin:-` is the documented "this atom installs no user-facing executable" opt-out.
    if [[ "$bin" != "-" && ! "$bin" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
      note "bin: $PKGS:$lineno ($atom) declares bin:$bin, which is not a command name"
    fi
    bins=$((bins + 1))
  elif [[ "$cmt" =~ (^|[[:space:]])[A-Za-z]*bin[A-Za-z]*[[:space:]]*: ]]; then
    note "bin: $PKGS:$lineno ($atom) looks like a \`# bin:\` contract but does not parse as one — scripts/assert-provisioned.sh reads \`bin:NAME\` with no space after the colon, and silently asserts the atom's own basename instead"
  fi

  if [[ "$cmt" =~ [[:space:]]min:([^[:space:]]+) ]]; then
    floor="${BASH_REMATCH[1]}"
    if [[ ! "$floor" =~ ^[0-9][0-9A-Za-z.:+~-]*$ ]]; then
      note "min: $PKGS:$lineno ($atom) declares min:$floor, which is not a version"
    fi
    mins=$((mins + 1))
  elif [[ "$cmt" =~ (^|[[:space:]])min[A-Za-z]*[[:space:]]*:[[:space:]]+[0-9] ]]; then
    note "min: $PKGS:$lineno ($atom) looks like a \`# min:\` floor but does not parse as one — scripts/check-packages.sh check 8 reads \`min:X.Y.Z\` with no space after the colon, so this declares a floor nothing enforces"
  fi
done <"$PKGS"
say "contracts: $bins \`# bin:\`, $mins \`# min:\`"

# ── 5 + 6. the rendered /etc/portage drop-ins ─────────────────────────────────
# Two fields, and the keyword must be the placeholder. bootstrap.sh substitutes
# __ARCH__ from `portageq envvar ARCH`, and .github/workflows/packages.yml seds the
# same token before resolving — so a literal keyword here is wrong in both places at
# once, and wrong SILENTLY: the file installs, and unmasks nothing off that arch.
kw=0
lineno=0
while IFS= read -r line; do
  lineno=$((lineno + 1))
  line="${line%%#*}"
  # Trim, then skip a blank or comment-only line.
  read -r -a f <<<"$line" || true
  ((${#f[@]})) || continue
  kw=$((kw + 1))

  # Any wildcard, not just the literal `*/*`: `app-shells/*` and `*/zoxide` unmask a
  # set nobody enumerated just as surely.
  if [[ "${f[0]}" == *'*'* ]]; then
    note "blanket: $KEYWORDS:$lineno unmasks '${f[0]}' — that file's own header says there should never be a wildcard here; keyword the atoms this repo installs, so everything else keeps tracking stable"
    continue
  fi
  if ((${#f[@]} != 2)); then
    note "shape: $KEYWORDS:$lineno has ${#f[@]} field(s), not 2 — a line here is \`<atom> <keyword>\`"
    continue
  fi
  # `>=app-editors/neovim-0.12.0` is the version-restricted form; a bare atom is the
  # unreachable form. Both are legal, an unparseable operator is not.
  if [[ ! "${f[0]}" =~ ^(\<|\<=|=|\>=|\>|~)?[a-z0-9]+(-[a-z0-9]+)*/[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
    note "shape: $KEYWORDS:$lineno ('${f[0]}') is not an atom spec"
  fi
  # `**` is deliberately excluded: this file's own header (the "arch scope-limit"
  # note at its bottom) says NOTHING HERE IS `**` — a `**` keyword is not
  # arch-scoped, so a `sys-block/dust **` accepts live/9999 ebuilds on every arch,
  # which is the blanket-unmask the top of the file refuses in another form. Two
  # rules, one policy: no `*/*` atom (checked above) and no `**` keyword.
  if [[ "${f[1]}" == '**' ]]; then
    note "__ARCH__: $KEYWORDS:$lineno keywords ${f[0]} as '**' — this file's header forbids that (a \`**\` is not arch-scoped and accepts live/9999 ebuilds on every arch, the blanket-unmask in a second form); use ~__ARCH__, or if the atom is unreachable in the tree, drop it rather than force it"
  elif [[ "${f[1]}" != '~__ARCH__' && "${f[1]}" != '__ARCH__' ]]; then
    note "__ARCH__: $KEYWORDS:$lineno keywords ${f[0]} as '${f[1]}' — use ~__ARCH__, which bootstrap.sh renders from \`portageq envvar ARCH\`; a hard-coded keyword installs cleanly and unmasks nothing off that arch"
  fi
done <"$KEYWORDS"
say "$KEYWORDS — $kw keyword line(s)"

lic=0
lineno=0
while IFS= read -r line; do
  lineno=$((lineno + 1))
  line="${line%%#*}"
  read -r -a f <<<"$line" || true
  ((${#f[@]})) || continue
  lic=$((lic + 1))
  ((${#f[@]} == 2)) || note "shape: $LICENSE:$lineno has ${#f[@]} field(s), not 2 — a line here is \`<atom> <license>\`"
done <"$LICENSE"
say "$LICENSE — $lic license line(s)"

# ── verdict ───────────────────────────────────────────────────────────────────
echo
if ((${#fails[@]})); then
  bad "${#fails[@]} manifest invariant(s) broken:"
  printf '    %s\n' "${fails[@]}" >&2
  cat >&2 <<'EOF'

None of these need a Portage tree to be wrong, which is why they are checked here
rather than in scripts/check-packages.sh (which skips without one) or in
.github/workflows/packages.yml (which is path-filtered).
EOF
  exit 2
fi
ok "manifests hold: shapes, no duplicate atom across the four lists, every \`# bin:\`/\`# min:\` contract parses, and every keyword line goes through __ARCH__."
