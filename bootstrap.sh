#!/usr/bin/env bash
# dotfiles-Gentoo/bootstrap.sh
# ──────────────────────────────────────────────────────────────────────────────
# Provision a Gentoo box and wire dotfiles. Idempotent. OS-NATIVE layer; Core
# (zsh/tmux/nvim/git) is vendored under core/. Gentoo is source-based: emerge
# COMPILES packages, so a full run can take a while. Two big mitigations are
# wired in below — the official binhost (--getbinpkg, auto-detected) and
# dev-lang/rust-bin (in packages.txt) instead of compiling Rust from source.
#
# Usage:
#   ./bootstrap.sh                 # sync + emerge atoms + extras + symlinks
#   ./bootstrap.sh --no-sync       # skip the (slow) `emerge --sync`
#   ./bootstrap.sh --links-only    # just (re)create symlinks
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
LINKS_ONLY=0
DO_SYNC=1

for a in "$@"; do case "$a" in
	--links-only) LINKS_ONLY=1 ;;
	--no-sync)    DO_SYNC=0 ;;
	-h | --help)
		sed -n '2,15p' "$0"
		exit 0
		;;
	*)
		echo "unknown arg: $a" >&2
		exit 1
		;;
	esac done

say() { printf '\e[36m::\e[0m %s\n' "$*"; }
ok() { printf '\e[32m+\e[0m %s\n' "$*"; }

# ── privilege tool: Gentoo's norm is sudo; doas is also common. root => none. ─
if [[ "$(id -u)" -eq 0 ]]; then
	SU=""
elif command -v sudo >/dev/null 2>&1; then
	SU="sudo"
elif command -v doas >/dev/null 2>&1; then
	SU="doas"
else
	echo "Need root: run as root, or install app-admin/sudo." >&2
	exit 1
fi

# ── Detect WSL ────────────────────────────────────────────────────────────────
IS_WSL=0
if [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
	IS_WSL=1
fi

# ── sanity: confirm we're on Gentoo ───────────────────────────────────────────
if ! grep -qiE '^ID=gentoo' /etc/os-release 2>/dev/null; then
	echo "This bootstrap targets Gentoo (expects ID=gentoo in /etc/os-release)." >&2
	exit 1
fi

# ── core/ subtree present? ────────────────────────────────────────────────────
if [[ ! -d "$DOTFILES/core/zsh" ]]; then
	echo "core/ subtree missing. One-time, run:" >&2
	echo "  git subtree add --prefix=core <dotfiles-core remote> main --squash" >&2
	exit 1
fi

link() {
	local src="$1" dst="$2"
	mkdir -p "$(dirname "$dst")"
	if [[ -L "$dst" ]]; then
		rm -f "$dst"
	elif [[ -e "$dst" ]]; then mv "$dst" "$dst.pre-dotfiles.$(date +%s)"; fi
	ln -s "$src" "$dst"
}

read_pkgs() {
	local line
	while IFS= read -r line; do
		line="${line%%#*}"
		line="${line//[[:space:]]/}"
		[[ -n "$line" ]] && printf '%s\n' "$line"
	done <"$1"
}

# ── emerge options: quiet builds, skip already-installed (idempotent re-runs),
# and pull binary packages IF a binhost is configured (huge time-saver; falls
# back to source compile otherwise). The official binhost ships configured on
# modern stage3 installs in /etc/portage/binrepos.conf{,.d}.
EMERGE_OPTS=(--quiet-build=y --noreplace)
if [[ -s /etc/portage/binrepos.conf ]] || ls /etc/portage/binrepos.conf.d/*.conf >/dev/null 2>&1; then
	EMERGE_OPTS+=(--getbinpkg=y)
fi

# ── resilient emerge: a single masked/keyworded atom aborts the whole set, so
# bulk first, then one-by-one so the rest still go in.
emerge_install() {
	local -a atoms=("$@")
	if $SU emerge "${EMERGE_OPTS[@]}" "${atoms[@]}"; then return 0; fi
	say "bulk emerge hit a snag (masked / keyworded atom?) — retrying one-by-one"
	local a
	for a in "${atoms[@]}"; do
		$SU emerge "${EMERGE_OPTS[@]}" "$a" ||
			echo "   skipped: $a  (try 'emerge -p $a' — likely needs a keyword/USE; see gentoo/package.accept_keywords.example)"
	done
}

provision() {
	if ((DO_SYNC)); then
		say "emerge --sync (Portage tree — slow; re-run with --no-sync to skip)"
		$SU emerge --sync --quiet || say "sync failed/!configured — continuing with the current tree"
	fi

	if [[ " ${EMERGE_OPTS[*]} " == *" --getbinpkg=y "* ]]; then
		say "binhost detected — pulling binary packages where available"
	else
		say "no binhost configured — building from source (see README to enable --getbinpkg)"
	fi

	say "emerge atoms (from install/packages.txt)"
	local -a atoms=()
	mapfile -t atoms < <(read_pkgs "$DOTFILES/install/packages.txt")
	emerge_install "${atoms[@]}"
	ok "atoms requested: ${#atoms[@]}"

	# mise — not in the main Gentoo tree; official installer (glibc build is fine).
	if ! command -v mise >/dev/null && [[ ! -x "$HOME/.local/bin/mise" ]]; then
		say "mise (official installer)"
		curl -fsSL https://mise.run | sh >/dev/null 2>&1 || true
	fi
	# tree-sitter-cli — not packaged; build via cargo (dev-lang/rust-bin provides it).
	if ! command -v tree-sitter >/dev/null && command -v cargo >/dev/null; then
		say "tree-sitter-cli (cargo build)"
		cargo install --locked tree-sitter-cli >/dev/null 2>&1 ||
			echo "   tree-sitter-cli build failed; retry later: cargo install tree-sitter-cli"
	fi
	# NOTE: starship / atuin / yazi are emerged from packages.txt on Gentoo (they
	# ARE in the main tree), so unlike the other repos there's no curl installer
	# for them here — stay on Portage.

	# ── WSL: install /etc/wsl.conf. No systemd=true — Gentoo defaults to OpenRC.
	if ((IS_WSL)); then
		say "installing /etc/wsl.conf (default user + interop; OpenRC default)"
		local user
		user="$(id -un)"
		sed "s/__WSL_USER__/$user/" "$DOTFILES/wsl/wsl.conf" | $SU tee /etc/wsl.conf >/dev/null
		ok "wsl.conf written — run 'wsl.exe --shutdown' from Windows, then reopen"
	fi
}

wire_links() {
	say "symlinking Core"
	for f in "$DOTFILES"/core/zsh/*.zsh; do
		link "$f" "$CONFIG/zsh/$(basename "$f")"
	done
	[[ -f "$DOTFILES/core/tmux/tmux.conf" ]] && link "$DOTFILES/core/tmux/tmux.conf" "$CONFIG/tmux/tmux.conf"
	[[ -f "$DOTFILES/core/tmux/tmux.reset.conf" ]] && link "$DOTFILES/core/tmux/tmux.reset.conf" "$CONFIG/tmux/tmux.reset.conf"
	if [[ -d "$DOTFILES/core/tmux/scripts" ]]; then
		link "$DOTFILES/core/tmux/scripts" "$CONFIG/tmux/scripts"
		chmod +x "$DOTFILES"/core/tmux/scripts/*.sh 2>/dev/null || true
	fi
	[[ -f "$DOTFILES/os/gentoo.conf" ]] && link "$DOTFILES/os/gentoo.conf" "$CONFIG/tmux/os.conf"
	if [[ ! -d "$CONFIG/tmux/plugins/tpm" ]]; then
		say "cloning tpm (tmux plugin manager)"
		git clone --depth=1 https://github.com/tmux-plugins/tpm "$CONFIG/tmux/plugins/tpm" >/dev/null 2>&1 &&
			ok "tpm cloned — run prefix+I in tmux to install plugins" ||
			say "tpm clone failed — clone it manually, then prefix+I"
	fi
	[[ -f "$DOTFILES/core/starship/starship.toml" ]] && link "$DOTFILES/core/starship/starship.toml" "$CONFIG/starship.toml"
	[[ -d "$DOTFILES/core/nvim" ]] && link "$DOTFILES/core/nvim" "$CONFIG/nvim"
	[[ -f "$DOTFILES/core/mise/config.toml" ]] && link "$DOTFILES/core/mise/config.toml" "$CONFIG/mise/config.toml"
	[[ -f "$DOTFILES/core/git/gitconfig" ]] && link "$DOTFILES/core/git/gitconfig" "$HOME/.gitconfig"
	[[ -f "$DOTFILES/os/gentoo.gitconfig" ]] && link "$DOTFILES/os/gentoo.gitconfig" "$CONFIG/git/os.gitconfig"
	if [[ ! -f "$CONFIG/git/local.gitconfig" && -f "$DOTFILES/core/git/local.gitconfig.example" ]]; then
		mkdir -p "$CONFIG/git"
		cp "$DOTFILES/core/git/local.gitconfig.example" "$CONFIG/git/local.gitconfig"
		say "seeded ~/.config/git/local.gitconfig — FILL IN your name & email"
	fi
	if [[ -d "$DOTFILES/core/bin" ]]; then
		mkdir -p "$HOME/.local/bin"
		for s in clip clip-paste; do
			if [[ -f "$DOTFILES/core/bin/$s" ]]; then
				link "$DOTFILES/core/bin/$s" "$HOME/.local/bin/$s"
				chmod +x "$DOTFILES/core/bin/$s" 2>/dev/null || true
			fi
		done
	fi
	if [[ -f "$DOTFILES/ssh/config" ]]; then
		say "symlinking ssh/config"
		mkdir -p "$HOME/.ssh/sockets"
		chmod 700 "$HOME/.ssh" "$HOME/.ssh/sockets"
		chmod 600 "$DOTFILES/ssh/config" 2>/dev/null || true
		link "$DOTFILES/ssh/config" "$HOME/.ssh/config"
		ok "~/.ssh/config linked (generate a key with: ssh-keygen -t ed25519)"
	fi

	say "symlinking Gentoo OS-native layer"
	link "$DOTFILES/os/gentoo.zsh" "$CONFIG/zsh/os.zsh"

	if [[ ! -f "$HOME/.zshrc" ]] || ! grep -q "dotfiles-managed v2" "$HOME/.zshrc" 2>/dev/null; then
		say "writing .zshrc loader"
		[[ -f "$HOME/.zshrc" ]] && cp "$HOME/.zshrc" "$HOME/.zshrc.pre-dotfiles.$(date +%s)"
		cat >"$HOME/.zshrc" <<'ZRC'
# dotfiles-managed v2 — do not hand-edit; put local tweaks in ~/.config/zsh/local.zsh
# This entry file sets the env the Core modules expect, then sources them in the
# ONE correct order. Mirror of the Mac's .zshrc.

# ── XDG + env ─────────────────────────────────────────────────────────────────
: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${XDG_STATE_HOME:=$HOME/.local/state}"
: "${XDG_CACHE_HOME:=$HOME/.cache}"
export EDITOR=nvim VISUAL=nvim
export NOTES_DIR="${NOTES_DIR:-$HOME/Notes}"

# ── Core modules + Gentoo os layer + local overrides, in canonical order ──
# history.zsh owns HISTFILE/HISTSIZE + history setopts; options.zsh owns the nav/glob
# setopts + compinit + completion zstyles — so this entry file no longer hand-rolls
# them. It declares the load order and sources the vendored Core loader
# (core/zsh/loader.zsh -> $ZSH_CFG/loader.zsh), which byte-compiles + sources each
# module. Loading the FULL set (ui/git/maint/update were silently missing) is the fix.
: "${ZDOTDIR:=$XDG_CONFIG_HOME/zsh}"
export ZDOTDIR              # Core modules (history/options) key state off ZDOTDIR;
ZSH_CFG="$ZDOTDIR"          # align the loader to the SAME dir so state never splits
_CORE_MODULES=(tools ui options history aliases git functions fzf bindings plugins op maint update os local)
if [[ -r "$ZSH_CFG/loader.zsh" ]]; then
  source "$ZSH_CFG/loader.zsh"
else
  print -u2 -- "zshrc: Core loader not found at $ZSH_CFG/loader.zsh — re-run the dotfiles bootstrap to (re)link Core."
fi
unset _CORE_MODULES
ZRC
	fi

	# make zsh the default LOGIN shell (Gentoo is glibc, so getent is present).
	if command -v zsh >/dev/null; then
		local zsh_path
		zsh_path="$(command -v zsh)"
		if ! getent passwd "$USER" | grep -q ":$zsh_path$"; then
			say "setting zsh as default login shell"
			grep -qxF "$zsh_path" /etc/shells || echo "$zsh_path" | $SU tee -a /etc/shells >/dev/null
			$SU chsh -s "$zsh_path" "$USER" && ok "default shell -> zsh (applies to NEW logins)"
		fi
	fi
	ok "symlinks wired"
}

((LINKS_ONLY)) || provision
wire_links
ok "Gentoo bootstrap complete — open a new shell or: exec zsh"
