# CLAUDE.md — dotfiles-Gentoo

Project memory for Claude Code, auto-loaded every session. For the shared Core
rules (the load order, the "is it Core?" test, the manifest contract) see
`core/README.md` and `core/CONTRIBUTING.md`.

## What this repo is

`dotfiles-Gentoo` is the **OS-native layer for Gentoo** in a **ten-repo dotfiles system** built on a three-layer
model (Core → OS-native → Role). Stamped from the Fedora template (see `core/PORTING-MATRIX.md`). Source-based — `emerge` **compiles** packages, so expect real build time. **USE flags** gate features at compile time, and package names are full atoms (`category/name`).

## The rule that bites

`core/` is a **vendored `git subtree` copy of [dotfiles-core](https://github.com/dotgibson/dotfiles-core)** — it
is *not* editable here. Anything you change under `core/` is overwritten on the
next sync. To change shared Core config, edit it **in dotfiles-core**, run
`make audit` there, then `make sync` to fan it out to every OS repo.

What belongs **here** is only the OS-native layer: the `emerge` package list (atoms), clipboard + paths, and the bootstrap.

## Where things are

- `os/gentoo.zsh` — clipboard + package-manager aliases for Gentoo
- `os/gentoo.conf`, `os/gentoo.gitconfig` — tmux + git OS overlays
- `install/packages.txt` — Gentoo atoms
- `gentoo/` — Gentoo-specific extras (USE flags, etc.)
- `bootstrap.sh` — symlinks Core + OS files into place
- `core/` — vendored Core (read-only here; edit upstream in dotfiles-core)
