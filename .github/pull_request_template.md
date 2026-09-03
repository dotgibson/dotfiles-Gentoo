## What and why

<!-- What changes, and what problem it solves. Link the issue if there is one. -->

## Layer check

This is the **OS-native layer for Gentoo**. Confirm the change is in the right repo:

- [ ] It is genuinely Gentoo-specific (Portage, USE flags, atoms, GURU, `/etc/portage`).
      If it would be identical on every distro it belongs in [dotfiles-core]; if it
      changes with the operator, it belongs in a role repo.
- [ ] It does **not** hand-edit `core/`. That tree is vendored and is overwritten by
      the next sync — fix it upstream in dotfiles-core instead.

## Verification

- [ ] `make lint` passes (shellcheck + `bash -n` + `zsh -n`)
- [ ] `make packages-check` passes (every atom exists and installs on a stable profile)
- [ ] `./bootstrap.sh --dry-run` shows the expected plan and nothing else
- [ ] If it changes provisioning: run on a real Gentoo box, and say which profile

<!-- Paste the relevant output. A Gentoo change that has only been reasoned about
     is worth saying so explicitly — stable-vs-testing keywords are exactly the
     class of thing that is wrong in ways only a real box shows. -->

[dotfiles-core]: https://github.com/dotgibson/dotfiles-core
