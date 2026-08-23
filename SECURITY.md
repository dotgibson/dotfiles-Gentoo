# Security Policy

`dotfiles-Gentoo` is the **OS-native layer for Gentoo** in a three-layer dotfiles
system. It ships configuration and one provisioning script; it is not a running
service and stores no credentials.

Two things here are nevertheless worth a security report rather than a normal
issue, because both run with elevated privileges or touch machine trust:

- **`bootstrap.sh`** runs `emerge` under `sudo`/`doas`, writes files under
  `/etc/portage` and `/etc/wsl.conf`, and installs binaries from `cargo`,
  `go install`, and the `mise` upstream installer. Anything that could redirect
  one of those to an attacker-controlled source, or escalate beyond the steps it
  declares, is a vulnerability — not a bug.
- **a tracked file leaking a secret.** `.gitignore` keeps SSH keys, `.env*`, and
  `*.pre-dotfiles.*` backups out of the tree, and `ssh/` is now ignored outright —
  the ssh client config moved into Core, so this repo tracks nothing there at all.
  A committed key or token is a security report.

`core/` is a **vendored copy of [dotfiles-core]** and is not maintained here. A
vulnerability in a `core/` file should be reported against that repo — it fans out
to every OS repo in the fleet, so fixing it here would fix exactly one of them.

## Reporting a vulnerability

**Please do not open a public issue.** Use GitHub's private vulnerability
reporting: the **Security** tab → **Report a vulnerability**.

Include, where you can:

- the file and line, and whether it sits in the OS layer or in vendored `core/`,
- how it is reached (a `bootstrap.sh` step, a shell alias, a symlinked config),
- what privilege it runs with, and
- a minimal reproduction.

## Scope notes

- **Not in scope:** the third-party tools this repo installs (`emerge` atoms, GURU
  overlay packages, crates, Go modules). Report those upstream — though if this
  repo installs a package from a source that is *itself* wrong (a typosquatted
  crate, an overlay that is not GURU), that very much is in scope.
- **Keyword and licence files** under `gentoo/` are installed to `/etc/portage`.
  They are per-atom by design; a change that broadened one to `*/*` would be a
  security-relevant regression.

[dotfiles-core]: https://github.com/dotgibson/dotfiles-core/security/policy
