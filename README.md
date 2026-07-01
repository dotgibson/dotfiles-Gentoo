# 🐧 dotfiles-Gentoo

**Gentoo, compiled to taste.** The Gentoo layer (Portage + USE flags) —
source-based, over the shared core.

`emerge` · `zsh` · `nvim` · `tmux`

[![showcase](https://img.shields.io/badge/showcase-live-7aa2f7?style=flat-square)](https://dotgibson.github.io/dotfiles-web/) ![Gentoo](https://img.shields.io/badge/Gentoo-source-bb9af7?style=flat-square)

---

The **OS-native layer** for Gentoo — the capstone of the set. Core
(zsh/tmux/nvim/git) is vendored under `core/` from
[`dotfiles-core`](../dotfiles-core); this repo adds only what is genuinely
Gentoo — Portage/`emerge`, full `category/name` atoms, USE flags, the
source-build mitigations.

Stamped from the `dotfiles-Fedora` template per `core/PORTING-MATRIX.md`. Gentoo
is the most educational and most time-expensive of the set: `emerge` **compiles**
packages, USE flags decide what gets built in, and tools are full atoms.

## Install (existing Gentoo system)

```sh
git clone <you>/dotfiles-Gentoo ~/dotfiles-Gentoo
cd ~/dotfiles-Gentoo
# one-time: vendor Core (skip if the repo already contains core/)
git subtree add --prefix=core <you>/dotfiles-core main --squash
./bootstrap.sh
exec zsh
```

Flags: `--no-sync` (skip the slow `emerge --sync` on re-runs), `--links-only`
(re-link without touching Portage). Run as root or with sudo/doas configured.

## Layout

```
bootstrap.sh                       emerge provision + symlink wiring (idempotent)
install/packages.txt               Portage atoms (modern CLI stack)
os/gentoo.zsh                      OS-native shell layer -> ~/.config/zsh/os.zsh
os/gentoo.gitconfig                OS git layer -> ~/.config/git/os.gitconfig
os/gentoo.conf                     tmux netspeed/battery -> ~/.config/tmux/os.conf
gentoo/package.use.example         USE-flag overrides to review + copy to /etc/portage
gentoo/package.accept_keywords.example  unmask ~arch tools if a stable profile blocks them
ssh/config                         hardened SSH client config -> ~/.ssh/config
wsl/wsl.conf                       installed to /etc/wsl.conf on WSL (no systemd; OpenRC)
core/                              vendored from dotfiles-core (do not hand-edit)
```

Load order in `.zshrc`: `core/tools → core/aliases → core/functions → core/fzf →
core/bindings → core/plugins → core/op → os/gentoo → local`.

## Gentoo specifics baked in (and the time-savers that matter)

- **It compiles from source — so cut the build time two ways.** (1) The
  **official binhost**: bootstrap auto-adds `--getbinpkg` when
  `/etc/portage/binrepos.conf{,.d}` is configured (it is on modern stage3s), so
  packages with a prebuilt binpkg install instead of compiling. Enable it if you
  haven't — it's the single biggest QoL win. (2) **`dev-lang/rust-bin`** (in the
  package list) gives you a prebuilt Rust/cargo so you skip a multi-hour
  toolchain compile; cargo then builds `tree-sitter-cli`.
- **USE flags are the whole point.** They gate features at compile time. Most of
  this stack builds on defaults, but see `gentoo/package.use.example` for the
  mechanism and a few you might want. Inspect with `equery uses <atom>` /
  `emerge -pv <atom>`; apply changes with `emerge -auvDN --newuse @world`.
- **Keyword masking.** On a stable profile, fast-moving Rust CLIs (eza, atuin,
  yazi, …) may be `~amd64` only and emerge will refuse them. `bootstrap.sh`'s
  resilient loop skips a blocked atom and tells you; unmask the ones you want via
  `gentoo/package.accept_keywords.example`.
- **Atoms are `category/name`** (`sys-apps/eza`, not `eza`) — the matrix and
  `install/packages.txt` use the full form to avoid ambiguity.
- **starship / atuin / yazi are in the main tree** here, so they're emerged like
  everything else — no curl installers (unlike the Fedora/openSUSE repos). Only
  **mise** (not in the tree) uses its installer, and **tree-sitter-cli** is cargo.
- **Living with Portage:** after a world update Portage often wants two
  follow-ups — `empreserved` (`emerge @preserved-rebuild`) and `emconf`
  (`dispatch-conf`, to merge `/etc` changes). And actually **read** `gnews`
  (`eselect news read`); Gentoo news items are how breaking changes are
  announced. `eix` (installed here) is the fast search.
- **WSL uses OpenRC, not systemd** by default — `wsl.conf` omits `systemd=true`
  (the file notes how to add it if you run the systemd profile). Run
  `wsl.exe --shutdown` after first bootstrap.
- Consider tuning `MAKEOPTS="-jN"` and `EMERGE_DEFAULT_OPTS="--jobs --load-average"`
  in `/etc/portage/make.conf` to parallelize builds (not auto-set by bootstrap).
