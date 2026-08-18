---
name: Feature request
about: A tool, alias, or bootstrap behaviour to add to the Gentoo layer
title: "feat: "
labels: enhancement
---

## What, and what it replaces

<!-- If it is a tool: what classic command does it replace, and what does it do
     that the current one doesn't? -->

## Layer

- [ ] Gentoo-specific — Portage atoms, USE flags, GURU, `/etc/portage` (belongs here)
- [ ] Identical on every distro — belongs in [dotfiles-core] instead
- [ ] Changes with the operator/engagement — belongs in a role repo

## Packaging on Gentoo

<!-- Which of these, and the exact atom or crate:
       ::gentoo            category/name, and whether it is stable on amd64
       GURU overlay        category/name
       cargo / go install  the CRATE or module path — these differ from the binary
                           name often enough to be a trap (jj-cli → jj,
                           watchexec-cli → watchexec)
       nowhere             say so; it may still be worth a documented manual path -->

[dotfiles-core]: https://github.com/dotgibson/dotfiles-core
