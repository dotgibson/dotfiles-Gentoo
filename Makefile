# dotfiles-Gentoo/Makefile
# ──────────────────────────────────────────────────────────────────────────────
# Local entry points for the checks CI runs, so a change can be verified BEFORE
# it is pushed. This repo had none: every check lived in a reusable workflow in
# dotfiles-core, which meant the only way to find out whether a change was good
# was to push it and wait.
#
# `make lint` deliberately mirrors dotfiles-core's lint-call.yml — same file
# selection (git ls-files, core/ excluded), same SHELLCHECK_OPTS, same advisory
# shfmt. If the two ever disagree, this one is wrong: the reusable workflow is
# the gate, this is the local echo of it.
#
# NB core.lock is written by dotfiles-core's sync-core.sh during a fan-out, not
# here — its own header tells you to run `make core-lock`, a target that has never
# existed in an OS repo (upstream: dotfiles-core#454). Deliberately not faking it:
# deriving core_sha locally without the Core remote would produce a lock that
# looks authoritative and is guessed.
# ──────────────────────────────────────────────────────────────────────────────
SHELL := /bin/bash
.DEFAULT_GOAL := help

# core/ is excluded everywhere: it is vendored and gated upstream by its own CI.
SH_FILES := $(shell git ls-files '*.sh' ':!:core/**')
ZSH_FILES := $(shell git ls-files '*.zsh' ':!:core/**')
export SHELLCHECK_OPTS := -e SC1090 -e SC1091 -e SC2015 -e SC2088

.PHONY: help lint shellcheck syntax fmt check-packages dry-run doctor secrets all

help: ## Show this help
	@echo "dotfiles-Gentoo — local checks"
	@echo
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Repo-owned shell: $(words $(SH_FILES)) .sh, $(words $(ZSH_FILES)) .zsh (core/ excluded)"

all: lint check-packages ## Everything CI can check locally

lint: shellcheck syntax ## shellcheck + bash -n + zsh -n (mirrors the CI gate)

shellcheck: ## Lint repo-owned bash with the fleet's SHELLCHECK_OPTS
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed (emerge dev-util/shellcheck)"; exit 1; }
	@echo "shellcheck $(SH_FILES)"
	@shellcheck $(SH_FILES)

syntax: ## Parse-check every repo-owned shell file
	@rc=0; for f in $(SH_FILES); do echo "bash -n $$f"; bash -n "$$f" || rc=1; done; \
	if command -v zsh >/dev/null; then \
		for f in $(ZSH_FILES); do echo "zsh -n $$f"; zsh -n "$$f" || rc=1; done; \
	else echo "zsh not installed — skipping zsh -n"; fi; \
	exit $$rc

fmt: ## Apply the 2-space shfmt style (advisory in CI, never blocking)
	@command -v shfmt >/dev/null || { echo "shfmt not installed (bootstrap.sh go-installs it)"; exit 1; }
	@shfmt -i 2 -w $(SH_FILES) && echo "formatted $(words $(SH_FILES)) file(s)"

check-packages: ## Verify every atom (packages.txt + the extras block + the GURU list) exists and installs on a stable profile
	@./scripts/check-packages.sh

dry-run: ## Preview a full bootstrap without changing anything
	@./bootstrap.sh --dry-run

doctor: ## Run core doctor in a Core shell (needs a completed bootstrap)
	@command -v zsh >/dev/null || { echo "zsh not installed — run ./bootstrap.sh first"; exit 1; }
	@zsh -ic 'core doctor' || true

secrets: ## Scan the repo-owned tree for committed secrets
	@command -v gitleaks >/dev/null || { echo "gitleaks not installed — see .gitleaks.toml for what this would run"; exit 1; }
	@gitleaks detect --no-banner --redact --config .gitleaks.toml
