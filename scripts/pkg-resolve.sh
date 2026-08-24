#!/usr/bin/env bash
# scripts/pkg-resolve.sh — resolve ONE Gentoo atom against the canonical package index.
# ──────────────────────────────────────────────────────────────────────────────
# The resolve command for `packages_check` in .github/workflows/bootstrap.yml. Core's
# reusable bootstrap-test.yml invokes it once per name as `<cmd> <atom>` and reads ONLY
# the exit status — stdout and stderr are both discarded, which shapes everything below.
#
#   exit 0  the atom exists upstream
#   exit 1  it does not (or we could not find out — see UNKNOWN below)
#   exit 2  usage error / no HTTP client at all
#
# WHY HTTP AND NOT portageq. `gentoo/stage3:latest` ships NO portage tree — verified in
# CI, where `portageq best_visible /` failed to resolve `app-shells/zsh`, a package that
# obviously exists. Getting a tree means `emerge-webrsync` (minutes, ~200k files), and the
# workflow's `prep` is SHARED with links-only and provision-stub, which finish in ~20s and
# gain nothing from it. So this asks packages.gentoo.org instead: no tree, no emerge, runs
# in seconds, and it is the canonical index for the question the gate actually asks —
# "did upstream rename or drop this?".
# The tradeoff, stated plainly: this checks the INDEX, not the ebuild tree, so it will not
# notice a package that is present but masked or unkeyworded for this arch.
#
# WHY curl-OR-wget. With no tree the container cannot emerge anything, so this must run on
# what stage3 already has. `net-misc/wget` is in Gentoo's system set; curl is not. Prefer
# curl when present (its %{http_code} is unambiguous), fall back to wget --spider.
#
# UNKNOWN (network failure, 5xx, a proxy eating the request) is retried, then treated as
# NOT FOUND — deliberately, and this is the one judgement call worth knowing about. With
# two exit codes and no visible output, the choice is a silent false green or a red. A red
# is DIAGNOSABLE: if the index is unreachable every atom fails at once, and nobody renames
# 40 packages in one day, so "all names UNRESOLVED" reads as a network problem, not as mass
# package rot. A silent green would be indistinguishable from real coverage — the failure
# mode Core's packages_check guidance exists to prevent.
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

readonly INDEX="https://packages.gentoo.org/packages"
readonly TIMEOUT="${PKG_RESOLVE_TIMEOUT:-20}"
readonly ATTEMPTS="${PKG_RESOLVE_ATTEMPTS:-4}"

atom="${1:-}"
if [[ -z "$atom" ]]; then
  echo "usage: ${0##*/} <category/package>" >&2
  exit 2
fi

# One probe. Echoes exactly one of: found | missing | unknown | notool
_probe() {
  local url="$1" code
  if command -v curl >/dev/null 2>&1; then
    # --max-time bounds the whole request; a transport failure leaves code empty -> 000.
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$url" 2>/dev/null)" || code="000"
    case "$code" in
      200) echo found ;;
      404) echo missing ;;
      *) echo unknown ;;
    esac
  elif command -v wget >/dev/null 2>&1; then
    # --spider issues a HEAD and sets the status by CLASS of failure:
    #   0 = OK, 8 = server returned an error response (404 lands here), 4 = network failure.
    wget -q --spider --tries=1 --timeout="$TIMEOUT" "$url" >/dev/null 2>&1
    case $? in
      0) echo found ;;
      8) echo missing ;;
      *) echo unknown ;;
    esac
  else
    echo notool
  fi
}

url="${INDEX}/${atom}"
attempt=0
while :; do
  case "$(_probe "$url")" in
    found) exit 0 ;;
    missing) exit 1 ;;
    notool)
      echo "${0##*/}: neither curl nor wget is available" >&2
      exit 2
      ;;
  esac
  attempt=$((attempt + 1))
  ((attempt >= ATTEMPTS)) && break
  sleep $((attempt * 3))
done
exit 1
