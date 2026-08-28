#!/usr/bin/env bash
# dotfiles-Gentoo/scripts/pkg-pending.sh
# ──────────────────────────────────────────────────────────────────────────────
# Print the package atoms a `@world` update would ACTUALLY change, one per line.
#
# WHAT READS THIS. os/gentoo.capabilities declares it as PKG_COUNT_PENDING, so it
# feeds both Core's once-a-day "N updates available" nudge and the list `up` previews
# — one implementation, so the number and the list can never disagree. bootstrap.sh
# symlinks it to ~/.local/bin/gentoo-pkg-pending, which is on $PATH for the
# interactive shell (os/gentoo.zsh) and is the first entry in the maint runner's
# baked PATH (core/maint/dotfiles-maint.sh), so both callers resolve it by name.
#
# WHY A SCRIPT AND NOT A ONE-LINER. Every other archive in the fleet declares a
# command line. Gentoo cannot: counting here needs the resolver's answer parsed, and
# a declaration may not reach into Core's internals (Core's own built-in row calls a
# private zsh function, which is exactly what an OS repo must not name). So the repo
# that owns the knowledge ships the implementation.
#
# WHY NOT eix, WHICH CORE USED TO USE (dotgibson/dotfiles-core#753, #756). `eix -u`
# answers "is a higher version present in the tree?"; `up` runs `emerge -uDN @world`,
# which answers "what will actually change?". On a healthy, fully-updated box those
# are permanently different questions, and the gap is not small — measured on a real
# machine, eix said 70 while emerge merged 8, and after a full update and depclean eix
# still said 2 against emerge's 0. Three distinct causes, only the first of which an
# operator can ever clear:
#
#   orphans        a package left installed but no longer reachable from @world. Any
#                  `emerge --unmerge` creates them; eix counts them, the resolver does
#                  not. 60 of the 64 on that box. Clears on --depclean.
#   SLOTS          dev-lang/lua-5.1.5-r200 IS the newest thing in SLOT 5.1, and six
#                  packages want that slot. eix compares against the highest version
#                  across ALL slots (5.4.8) and reports an upgrade that cannot exist.
#   consumer pins  app-editors/neovim RDEPENDs `=dev-libs/tree-sitter-c-0.24.1*`.
#                  Both versions are stable and same-slot; the resolver refuses to move
#                  because a dependent pinned it. eix sees only the tree.
#
# The last two NEVER clear. So this is not eix being imprecise — it is eix being
# structurally unable to answer the question, and no filter over its output fixes
# slots or pins. Only the resolver knows, so ask it.
#
# ON THE COST. ~10s against eix's 0.25s. The caller that pays it is throttled to
# UPDATE_CHECK_INTERVAL (once a day) and runs disowned, so it never blocks a prompt.
# A once-a-day background resolve is affordable; a permanently wrong number is not,
# because a nudge that cannot reach zero on a healthy box stops being a signal.
#
# NOT PRIVILEGED and takes NO merge lock: --pretend resolves and installs nothing, so
# this is safe to run beside a real emerge.
#
# EXIT STATUS IS LOAD-BEARING. A non-zero exit means "could not answer", and
# os/gentoo.capabilities declares PKG_COUNT_EXIT_TRUSTED=1 so Core reports its unknown
# sentinel instead of 0. An emerge that cannot resolve must never read as "up to date".
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

command -v emerge >/dev/null 2>&1 || exit 1

# Same selection `up` executes (-uDN @world), so the preview cannot drift from the
# action. A failed resolve emits nothing AND exits non-zero, so the caller can tell
# "no updates" from "could not ask".
out="$(emerge --pretend --update --deep --newuse @world 2>/dev/null)" || exit 1

printf '%s\n' "$out" | awk '
  # Only real merges. [nomerge]/[blocks]/[uninstall] are not upgrades.
  /^\[(ebuild|binary)/ {
    sub(/^\[[^]]*\][[:space:]]*/, "")
    split($0, f, /[[:space:]]+/)
    atom = f[1]
    sub(/::.*/, "", atom)            # drop ::repo
    sub(/-r[0-9]+$/, "", atom)       # PVR is PV plus an optional -rN,
    sub(/-[0-9][^-]*$/, "", atom)    #   so the revision comes off first
    if (atom ~ /\//) print atom
  }'
