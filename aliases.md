# Gentoo Aliases Cheat Sheet

OS-specific aliases from `os/gentoo.zsh`. See `core/` for the universal alias
reference (modern CLI, git, safety nets) that applies on every machine.

If `doas` is available and `sudo` is absent, an alias is created automatically so
privilege-escalation muscle memory works without changes. Package names are full atoms
(`category/name`); `emerge` compiles from source, so expect real build time. Prefer
`dev-lang/rust-bin` over `dev-lang/rust` to avoid compiling the Rust toolchain.

## Privilege Escalation

| Alias | Expands To | Condition |
|-------|-----------|----------|
| `sudo` | `doas` | `sudo` not installed and `doas` present |

## Package Management (emerge / Portage)

| Alias | Expands To |
|-------|------------|
| `emi` | `sudo emerge -av` (install with confirmation) |
| `emu` | `sudo emerge -auvDN @world` (full system upgrade) |
| `emr` | `sudo emerge -av --depclean` (remove + clean deps) |
| `emsync` | `sudo emerge --sync` (sync Portage tree) |
| `emsearch` | `emerge -s` — or `eix` if installed (faster, conditional override) |
| `embelongs` | `equery belongs` (which package owns a file) |
| `emuses` | `equery uses` (show USE flags for a package) |
| `empreserved` | `sudo emerge @preserved-rebuild` |
| `emconf` | `sudo dispatch-conf` (merge config file updates) |
| `gnews` | `sudo eselect news read` |

> **Note on `emsearch`:** If `eix` is installed, it overrides `emerge -s` — `eix`
> is significantly faster for searching the Portage tree.

## Clipboard / WSL / Navigation

| Alias | Expands To | Condition |
|-------|-----------|----------|
| `pbcopy` | `clip` | clip available |
| `pbpaste` | `clip-paste` | clip-paste available |
| `dotsync` | `cd "$HOME/dotfiles-Gentoo"` | always |
| `opsignin` | `eval "$(op signin)"` | 1Password CLI |
| `localip` | `ip -brief -4 addr show scope global` | always |
| `open` | `explorer.exe` | WSL |
| `xdg-open` | `wslview` | WSL + wslview |
| `cdwin` | `cd "$WINHOME"` | WSL + WINHOME set |
