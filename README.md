<!-- Back to top link -->
<a id="readme-top"></a>

<!-- Project Shields -->
<div align="center"><nobr>

[![dotgibson][dotgibson-shield]][dotgibson-url]<!--
-->[![CI][ci-shield]][ci-url]<!--
-->![Last Commit][lastcommit-shield]<!--
-->[![Contributors][contributors-shield]][contributors-url]<!--
-->[![Forks][forks-shield]][forks-url]<!--
-->[![Stargazers][stars-shield]][stars-url]<!--
-->[![Issues][issues-shield]][issues-url]<!--
-->[![MIT License][license-shield]][license-url]

</nobr></div>

<!-- PROJECT LOGO -->
<br />
<div align="center">
  <a href="https://github.com/dotgibson/">
    <img src="https://raw.githubusercontent.com/dotgibson/.github/main/profile/logo.png" alt="Logo" width="80" height="80">
  </a>

  <h3 align="center">🐧 dotfiles-Gentoo</h3>

  <p align="center">
    The Gentoo OS-native layer — Portage, USE flags, source-based, over the shared Core.
    <br />
    <a href="https://dotgibson.github.io/dotfiles-web/docs"><strong>Explore the docs »</strong></a>
    <br />
    <br />
    <a href="https://dotgibson.github.io/dotfiles-web/playground/">View Demo</a>
    &middot;
    <a href="https://github.com/dotgibson/dotfiles-Gentoo/issues/new?labels=bug">Report Bug</a>
    &middot;
    <a href="https://github.com/dotgibson/dotfiles-Gentoo/issues/new?labels=enhancement">Request Feature</a>
  </p>
</div>

<!-- TABLE OF CONTENTS -->
<details>
  <summary>Table of Contents</summary>
  <ol>
    <li>
      <a href="#about-the-project">About The Project</a>
      <ul>
        <li><a href="#languages">Languages</a></li>
        <li><a href="#tools">Tools</a></li>
      </ul>
    </li>
    <li><a href="#getting-started">Getting Started</a></li>
    <li><a href="#whats-in-this-layer">What's In This Layer</a></li>
    <li><a href="#contributing">Contributing</a></li>
    <li><a href="#license">License</a></li>
    <li><a href="#contact">Contact</a></li>
  </ol>
</details>

<!-- ABOUT THE PROJECT -->
## About The Project

**`dotfiles-Gentoo` is the OS-native layer for Gentoo** — the capstone of the
Linux set, and one node in a cross-platform dotfiles system. The shared **Core**
(zsh, tmux, Neovim, git, starship, mise) is authored once in
[`dotfiles-core`](https://github.com/dotgibson/dotfiles-core) and vendored under
`core/` via `git subtree`, so a clone is self-contained. This repo adds only what
is genuinely Gentoo: Portage/`emerge`, full `category/name` atoms, USE flags, and
the source-build mitigations.

Gentoo is stamped from the [`dotfiles-Fedora`](https://github.com/dotgibson/dotfiles-Fedora)
template per the [porting matrix][porting] — the most educational and most
time-expensive of the set, since `emerge` **compiles** packages. The full docs
live on the [documentation site][docs].

The system is three layers, each building on the one below:

| Layer | Lives in | Owns |
| --- | --- | --- |
| **Core** | [`dotfiles-core`](https://github.com/dotgibson/dotfiles-core) → vendored into every OS repo's `core/` | zsh, tmux, nvim, git, starship — identical everywhere |
| **OS-native** | `dotfiles-{MacBook,Windows,Fedora,Arch,openSUSE,Alpine,Gentoo}` (this repo among them) | package manager, clipboard, paths |
| **Role** | `dotfiles-Kali`, `dotfiles-Defense` | offensive / defensive tooling |

### Languages

No new languages — this layer is shell and package config over
[Core's language stack](https://github.com/dotgibson/dotfiles-core#languages).

### Tools

- [![Gentoo][gentoo-shield]][gentoo-url]
- [![Portage][portage-shield]][portage-url]
- [![eix][eix-shield]][eix-url]

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- GETTING STARTED -->
## Getting Started

### Prerequisites

An existing Gentoo system and **Git**, run as root or with `sudo`/`doas`
configured. Because `emerge` compiles from source, expect real build time — the
hub write-up covers the two biggest time-savers (the binhost and `rust-bin`).

### Installation

```sh
git clone https://github.com/dotgibson/dotfiles-Gentoo ~/dotfiles-Gentoo
cd ~/dotfiles-Gentoo
./bootstrap.sh
exec zsh
```

`core/` is a vendored subtree and is **already present** in a clone — there is no
submodule step. `bootstrap.sh` is idempotent: it emerges the package list
(skipping and reporting any keyword-masked atom) and symlinks Core + the Gentoo
layer into place. Flags: `--no-sync` (skip the slow `emerge --sync` on re-runs),
`--links-only` (re-link without touching Portage).

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- WHAT'S IN THIS LAYER -->
## What's In This Layer

Only what changes with the OS. The heavy lifting — the shell modules, editor, and
prompt — comes from vendored Core; this repo owns the Gentoo specifics:

- `bootstrap.sh` — `emerge` provision + Core/OS symlink wiring (idempotent)
- `install/packages.txt` — Portage atoms (modern CLI stack)
- `os/gentoo.zsh` — clipboard + package-manager aliases → `~/.config/zsh/os.zsh`
- `gentoo/package.use.example`, `gentoo/package.accept_keywords.example` — USE-flag and keyword overrides to review and copy to `/etc/portage`
- `core/` — vendored from `dotfiles-core` (read-only here; edit upstream)

The things that actually bite on Gentoo — cutting build time (binhost +
`rust-bin`), USE flags, keyword masking, full atoms, and living with Portage
(`@preserved-rebuild`, `dispatch-conf`, `gnews`) — are written up on the hub,
alongside the per-distro **[porting matrix][porting]**:

> **[→ dotfiles-Gentoo on the documentation hub][repo-docs]**

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- CONTRIBUTING -->
## Contributing

This is an **OS-native layer**, so the contribution rule is a boundary rule:

1. **Never hand-edit `core/`.** It is a vendored copy of `dotfiles-core` and is
   overwritten on the next sync. Fix shared config **upstream** in
   `dotfiles-core`, run `make audit` there, then `make sync` fans it out here.
2. **Keep changes genuinely Gentoo.** If it would be identical on every distro,
   it belongs in Core; if it changes with the operator, it belongs in a role repo.
3. **Green the lint gate.** This repo's CI runs shellcheck + `bash -n` / `zsh -n`
   on the repo-owned shell (the vendored `core/` is excluded — it is gated
   upstream).

Bugs and ideas: open an
[issue](https://github.com/dotgibson/dotfiles-Gentoo/issues).

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- LICENSE -->
## License

Distributed under the MIT License. See [`LICENSE`](LICENSE) for more information.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- CONTACT -->
## Contact

Garrett Allen - [@gerrrrt](https://x.com/gerrrrt) - <garrettallen2@gmail.com> - [LinkedIn](https://linkedin.com/in/garrettallen2)

Project Link: [dotgibson](https://github.com/dotgibson/)

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- Markdown Links & Images -->
[repo-docs]: https://dotgibson.github.io/dotfiles-web/docs/repos/dotfiles-Gentoo
[porting]: https://dotgibson.github.io/dotfiles-web/docs/reference/porting-matrix
[dotgibson-shield]: https://img.shields.io/github/v/release/dotgibson/dotfiles-core?style=flat-square&label=dotgibson&labelColor=181717&logo=data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAF1klEQVR4nLSWbUxT7RnHr9PT09MXSltaoC9QXkqR16Iwhb0Iw8VYYE7jPri5aBaZzpmFZbpolpn4QeMyM%2BM%2B7MVt0Q9LNJIlxCzqxGWS6aKAig51vBQKIi3QltpCS0%2Fbc879pD1N3%2Bnz4fG5Pl2977v%2F331d131f5%2BZrddWQZAgAgy9uCRlefICzT6GeIsP%2FXF15kahmu9JglGmLRQoRQdIQWgu77BuWGe%2Fo%2BOqym8odApaWomTT1%2Bl2HqirahaTuJ9kQMggkgYhDRGfRiQDZBi9fuf52%2BD7l1b3ZhRcmq%2FMnBHmibuO7fvWoTalVoDjQRwL8RGgEOtzB0MbtBDnkRjGR0AgTK%2BQfNukr1LKXlhXKZpJSxTKGoFSq9vf16tQ8%2FiEh094Vu0L449mLGMup20DRWuFYVCiFm%2BvU36nTbOlMB%2BnCDxIOBzhvv6nFpc3TS0dUKDRHzh1Jk9O8wlPYN326Oa%2FJobnN8shAOxqKjrdXa8WSnGKWPewR%2FuHLG5P8oKUFJHi%2FH19F6UKEQ%2BnbJap27%2B%2BtWR15VAHgLkV%2F%2F0xW6OuQCfNE4PgmyX6f0xZKYbJDuj43lmtoYqHU%2FaZdwNXr4eoUG51zqgw%2B%2FCtrbm0UCeRynBhqVj2YC4RNC%2FuqStbKkydAODzeO7%2B6QYTpnOIYgB729R729RY9DAGafb0wDOHLwAA5vKK1mJNFoCpsxeLLn%2Fy91uU359719%2FfVXL%2BSM35IzU9rcXciCcQujz0imOfbGhOB0jkGo2hFQBW7Quzr0Zzq6vyBT%2FuKY%2BHErfBmQWLK1Lhr6l1OkleCqC0poPb%2FuTwv3OrA8DPDhgkokgLmLX77o86kqcGJmaj5xjr1JWlAAr1Js75MDEGAAI%2B1mvWX%2F1JY29XmYDPS5ZoNsrM24si1xSh3%2FRbGBYlz%2F73g41ztqliqYv1onyVHgDocMjjXASAKycavlqnZBHa2ajcasjv%2B8MbAPhRV9nI5MezB41crIPPHWOW9Gtl9XhDDCMCokIqSwGQ4shvyucFhEQCnqlSdm9k%2BdKt6XM%2FqO7aof7t8YbIIW5SHdpVIhUTAOAP0L8bmM3MHgJwByidQCgnhSmAqOEYnQ8AgRBr%2FuUzKsgggIs3pyVCfkeTCgAmFtaNOgm39C%2F3511r2W8JYvIAJbIaAwQ3vKAEoVgRaTQIBYKxqxgMs6euvdUXiQDgeHd5rV7K1fb2kC2rOgaYghQBMJ5grI3HUGuuhQiNIOWq8sy%2FLTgCKplgT0ZtCyprWw7%2FvKCyNr6yQqYg8cim59a9KQDnwv84R1%2F99UwAzsMya4vxeOYLN7YePGG%2BcAPjxXS%2BoavknFfOlRTAh8nHKNqLa1v2ZwK6dxQZtHk5ahu3%2FcYmLsoh%2B%2FsUgN%2BztDQzEvkYFBurGnan%2FS1%2B1P98L1FbxLIPzh193X%2FtwbmjiGUBYHd5nVFRCABPlxdtfh%2B3LHGKxof%2Bqo90C6yj58yi9Tm1kWjr94ZXsGhTuDuynAx2z0245yY4X06Kf9HWFd0N%2BuPbsUR64%2B3a57Erig2qIoOIlJSUNE69GWTZRFufXvRNL%2Fo2ywyJE1fMP6xWqHBEP5yfvP7%2FbAAAsFufG01mkVCqkGvLyrbNTD2mw9kfDckmE0oudx9rUZfhiF5Zd%2F%2F00QDF0NkBTJhanB3e0riHJIRKhXarqWfdu%2Bx0WnOot1ftuNR90lhQzEO0L7B2YvCm3b%2BWNI%2ByffSLq757%2BPcquYaIvBtgdcXycuzO9MzTFdccd9IwDNMVlDaXbzPXtxsVhQRDEQzl8i6d%2Buf12Y%2BONDVMo6vOfHWJxHLz3l811u8WAEZABCNAAHSI8n8k2HABKRJjLJ8JECxFMAE%2BHXhiGb7yn35vcCNDKVsEcSuv%2BEpn%2B7Etla0CwAQIOBLBhrkt85kAnwm8mX95e%2FTOa9vUZiIxQI43r0Kura9uN5SYNMoyuVDGZ2nK73C65iy28Rezo44152bSKYAvz3ifVA1lDn0WAAD%2F%2F%2FWvXexgMwqgAAAAAElFTkSuQmCC
[dotgibson-url]: https://github.com/dotgibson/dotfiles-core/releases/latest
[ci-shield]: https://img.shields.io/github/actions/workflow/status/dotgibson/dotfiles-Gentoo/lint.yml?branch=main&style=flat-square&logo=githubactions&logoColor=white&label=CI
[ci-url]: https://github.com/dotgibson/dotfiles-Gentoo/actions/workflows/lint.yml
[lastcommit-shield]: https://img.shields.io/github/last-commit/dotgibson/dotfiles-Gentoo?branch=main&style=flat-square&logo=git&logoColor=white
[contributors-shield]: https://img.shields.io/github/contributors/dotgibson/dotfiles-Gentoo.svg?style=flat-square&logo=github
[contributors-url]: https://github.com/dotgibson/dotfiles-Gentoo/graphs/contributors
[forks-shield]: https://img.shields.io/github/forks/dotgibson/dotfiles-Gentoo.svg?style=flat-square&logo=github
[forks-url]: https://github.com/dotgibson/dotfiles-Gentoo/network/members
[stars-shield]: https://img.shields.io/github/stars/dotgibson/dotfiles-Gentoo.svg?style=flat-square&logo=github
[stars-url]: https://github.com/dotgibson/dotfiles-Gentoo/stargazers
[issues-shield]: https://img.shields.io/github/issues/dotgibson/dotfiles-Gentoo?style=flat-square&logo=github
[issues-url]: https://github.com/dotgibson/dotfiles-Gentoo/issues
[license-shield]: https://img.shields.io/github/license/dotgibson/dotfiles-Gentoo.svg?style=flat-square
[license-url]: https://github.com/dotgibson/dotfiles-Gentoo/blob/main/LICENSE
[docs]: https://dotgibson.github.io/dotfiles-web/docs
[gentoo-shield]: https://img.shields.io/badge/Gentoo-54487A?style=flat-square&logo=gentoo&logoColor=white
[gentoo-url]: https://www.gentoo.org
[portage-shield]: https://img.shields.io/badge/Portage_·_emerge-54487A?style=flat-square
[portage-url]: https://wiki.gentoo.org/wiki/Portage
[eix-shield]: https://img.shields.io/github/v/release/vaeth/eix?style=flat-square&logo=gnometerminal&logoColor=24283B&label=eix&labelColor=BB9AF7&color=3D59A1
[eix-url]: https://github.com/vaeth/eix
