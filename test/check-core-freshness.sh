#!/usr/bin/env bash
# test/check-core-freshness.sh — is the vendored core/ subtree BEHIND upstream?
# ──────────────────────────────────────────────────────────────────────────────
# The vendored core/ here is a git-subtree copy of dotfiles-core. Nothing on THIS
# side tracked whether that copy had fallen behind upstream — so a security/bugfix
# landing in Core could sit un-pulled here indefinitely. This is the consumer-side
# freshness watcher: it asks whether the vendored commit is now BEHIND upstream's
# tip, i.e. there are Core updates this repo hasn't pulled. A behind result is the
# NUDGE to run a `git subtree pull`, not a hard error in normal development — so it
# lives in a SCHEDULED workflow.
#
# Exit codes (matching dotfiles-core's drift-check convention — see
# core/scripts/update-plugins.sh --check):
#   0  current, OR a graceful skip (no git, offline/restricted, not a subtree checkout)
#   2  vendored core/ is BEHIND upstream (drift — the nudge to `git subtree pull`)
#   1  a genuine hard failure (e.g. a malformed core.lock)
# The workflow branches on these so a skip, a drift, and a real error each render the
# right step summary. Override the upstream/branch with CORE_UPSTREAM / CORE_BRANCH.
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1

# Palette + glyphs from the VENDORED shared bash UX lib (core/lib/ux.sh) — ONE colour/glyph
# rule instead of hand-rolled copies that drift. If core/ is incomplete the lib won't be
# readable, so fall back to no colour and ASCII glyphs rather than fail to source it; the
# explicit core/ presence check below is what actually decides "not a subtree checkout".
if [[ -r "$REPO/core/lib/ux.sh" ]]; then
  # shellcheck source=/dev/null
  source "$REPO/core/lib/ux.sh"
  c_g=$UX_GRN c_y=$UX_YEL c_r=$UX_RED c_0=$UX_RST
else
  c_g='' c_y='' c_r='' c_0=''
fi
# ASCII fallbacks when ux.sh is absent; when it's present these are already the
# locale-correct glyph (✓/⚠/… on UTF-8, ok/!/… otherwise), so := leaves them be.
: "${UX_OK:=ok}" "${UX_WARN:=!}" "${UX_ERR:=x}" "${UX_INFO:=-}"

skip() {
  printf '%s%s%s %s\n' "$c_y" "$UX_INFO" "$c_0" "$*"
  exit 0
}

# A non-subtree checkout has no vendored core/ to compare — skip cleanly (and keep the
# core.lock-present-but-core/-missing case from reporting a misleading "behind").
[[ -d core ]] || skip "check-core-freshness: no vendored core/ (not a subtree checkout?)"
command -v git >/dev/null 2>&1 || skip "check-core-freshness: git unavailable"

# Prefer the O(1) offline provenance stamp (core.lock, written by dotfiles-core's
# sync-core.sh); fall back to the subtree-split marker (which needs full history) when it's
# absent. Either yields the commit the vendored core/ was last synced from.
SPLIT=""
if [[ -r core.lock ]]; then
  SPLIT="$(sed -n 's/^core_sha=//p' core.lock | head -n1)"
  # A present-but-malformed lock would make the TIP-vs-SPLIT compare below report a false
  # "behind". This is a real misconfiguration, not drift, so fail HARD (exit 1) with a
  # clear message rather than emit a misleading verdict.
  if [[ ! "$SPLIT" =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s%s%s check-core-freshness: core.lock has an invalid core_sha (%s) — expected a 40-char hex SHA\n' \
      "$c_r" "$UX_ERR" "$c_0" "${SPLIT:-empty}" >&2
    exit 1
  fi
fi
[[ -n "$SPLIT" ]] || SPLIT="$(git log --grep='git-subtree-dir: core' -n1 --format='%b' 2>/dev/null |
  sed -n 's/^[[:space:]]*git-subtree-split:[[:space:]]*//p' | head -n1)"
[[ -n "$SPLIT" ]] || skip "check-core-freshness: no core.lock or git-subtree-split marker (not a subtree checkout?)"

UPSTREAM="${CORE_UPSTREAM:-https://github.com/dotgibson/dotfiles-core}"
BRANCH="${CORE_BRANCH:-main}"

# Resolve BRANCH to an explicit refs/heads/<branch> so ls-remote can't match a same-named
# tag (a bare name is a ref PATTERN). A caller may still pass a full refs/… via CORE_BRANCH.
case "$BRANCH" in
refs/*) ref="$BRANCH" ;;
*) ref="refs/heads/$BRANCH" ;;
esac
# The upstream tip we'd be pulling. ls-remote needs no clone; GIT_TERMINAL_PROMPT=0 keeps it
# non-interactive (never block a scheduled run waiting on a credential prompt).
TIP="$(GIT_TERMINAL_PROMPT=0 git ls-remote "$UPSTREAM" "$ref" 2>/dev/null | awk 'NR==1{print $1}')"
[[ -n "$TIP" ]] || skip "check-core-freshness: cannot reach $UPSTREAM ($BRANCH) — offline/restricted?"

if [[ "$TIP" == "$SPLIT" ]]; then
  printf '%s%s%s vendored core/ is current with %s@%s (%s)\n' "$c_g" "$UX_OK" "$c_0" "$UPSTREAM" "$BRANCH" "${SPLIT:0:12}"
  exit 0
fi

# Behind (or diverged). Report the SHAs and how to update, then exit 2 (drift) so a
# scheduled run surfaces it as a nudge — distinct from the exit-1 hard failures above.
# This repo has no Makefile, so the remediation is the raw subtree pull + a links-only
# bootstrap re-run, printed as two copy-pasteable commands (no trailing comma/prose).
{
  printf '%s%s%s vendored core/ is behind upstream %s@%s\n' "$c_y" "$UX_WARN" "$c_0" "$UPSTREAM" "$BRANCH"
  printf '    vendored: %s\n    upstream: %s\n' "${SPLIT:0:12}" "${TIP:0:12}"
  printf '    update:\n'
  printf '      git subtree pull --prefix=core %s %s --squash\n' "$UPSTREAM" "$BRANCH"
  printf '      ./bootstrap.sh --links-only\n'
} >&2
exit 2
