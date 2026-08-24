---
name: Bug report
about: Something in the Gentoo layer is broken — bootstrap, an atom, an alias
title: "bug: "
labels: bug
---

<!--
Is it actually a Gentoo problem? Anything under core/ (zsh modules, nvim, tmux,
git config, the bootstrap-lib scaffold) is VENDORED from dotfiles-core and is
overwritten on the next sync — file those at dotgibson/dotfiles-core.
This repo owns: bootstrap.sh, install/packages.txt, os/gentoo.*, gentoo/*, wsl/.
-->

## What's wrong

## Box

- profile: <!-- eselect profile show -->
- arch / `ARCH`:
- WSL or bare metal:
- `core.lock` `core_version`:

## How to reproduce

```console
./bootstrap.sh --dry-run
```

<!-- If an atom failed to emerge, the useful output is `emerge -p <category/name>`:
     it names the exact keyword, licence or USE that is blocking. -->

## What you expected
