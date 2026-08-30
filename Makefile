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
# Same pathspec, and it is the one lint-call.yml's markdown leg uses — so `make markdown`
# scans exactly what the blocking gate scans, recursively. A '*.md' glob would be
# top-level only and miss all three .github/ templates.
MD_FILES := $(shell git ls-files '*.md' ':!:core/**')
export SHELLCHECK_OPTS := -e SC1090 -e SC1091 -e SC2015 -e SC2088

.PHONY: help lint shellcheck syntax markdown fmt check-packages assert-provisioned dry-run doctor secrets all capabilities

help: ## Show this help
	@echo "dotfiles-Gentoo — local checks"
	@echo
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Repo-owned shell: $(words $(SH_FILES)) .sh, $(words $(ZSH_FILES)) .zsh, $(words $(MD_FILES)) .md (core/ excluded)"

all: lint check-packages ## Everything CI can check locally

lint: shellcheck syntax markdown capabilities ## shellcheck + bash -n + zsh -n + markdownlint (mirrors the CI gate)

shellcheck: ## Lint repo-owned bash with the fleet's SHELLCHECK_OPTS
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed (emerge dev-util/shellcheck-bin — NOT dev-util/shellcheck, which is Haskell and cannot resolve on a stable profile; see install/packages.txt)"; exit 1; }
	@echo "shellcheck $(SH_FILES)"
	@shellcheck $(SH_FILES)

syntax: ## Parse-check every repo-owned shell file
	@rc=0; for f in $(SH_FILES); do echo "bash -n $$f"; bash -n "$$f" || rc=1; done; \
	if command -v zsh >/dev/null; then \
		for f in $(ZSH_FILES); do echo "zsh -n $$f"; zsh -n "$$f" || rc=1; done; \
	else echo "zsh not installed — skipping zsh -n"; fi; \
	exit $$rc

# Markdown had no local gate at all, while lint-call.yml's markdown leg has been BLOCKING
# since dotgibson/dotfiles-core#592 — a required check nobody could run before pushing, and
# a .markdownlint.jsonc only CI ever read.
#
# SKIPS when absent, like `syntax` does for zsh and unlike `shellcheck` above which exits 1.
# shellcheck is an emerge-able package; markdownlint-cli2 is npm-only, so failing on its
# absence would red `make lint` on most boxes for something the author cannot cheaply fix.
# ONE recipe line, so the skip ends the whole target rather than just its first line
# (dotgibson/dotfiles-core#775).
markdown: ## markdownlint the repo-owned *.md against .markdownlint.jsonc (skips if absent)
	@if ! command -v markdownlint-cli2 >/dev/null 2>&1; then \
	  echo "markdownlint-cli2 not installed — skipping (npm i -g markdownlint-cli2; CI still enforces it)"; \
	elif [ -z "$(MD_FILES)" ]; then echo "no repo-owned .md"; \
	else echo "markdownlint-cli2 $(MD_FILES)"; markdownlint-cli2 $(MD_FILES); fi

fmt: ## Apply the 2-space shfmt style (advisory in CI, never blocking)
	@command -v shfmt >/dev/null || { echo "shfmt not installed (bootstrap.sh go-installs it)"; exit 1; }
	@shfmt -i 2 -w $(SH_FILES) && echo "formatted $(words $(SH_FILES)) file(s)"

check-packages: ## Verify every atom (packages.txt + both extras lists + the GURU list) exists and installs on a stable profile
	@./scripts/check-packages.sh

# The other half of the same question, asked from the other side of a real run.
# check-packages asks "could this install?" against a Portage tree; this asks "did
# it?" against $$PATH, and only the second one can see a box that finished green
# while shipping without shellcheck (issue #133).
assert-provisioned: ## After a real bootstrap: assert every packages.txt atom put its binary on PATH
	@./scripts/assert-provisioned.sh

dry-run: ## Preview a full bootstrap without changing anything
	@./bootstrap.sh --dry-run

doctor: ## Run core doctor in a Core shell (needs a completed bootstrap)
	@command -v zsh >/dev/null || { echo "zsh not installed — run ./bootstrap.sh first"; exit 1; }
	@zsh -ic 'core doctor' || true

# --config core/gitleaks.toml is the ONE fleet policy — the same file Core's reusable
# lint-call.yml passes for the blocking CI leg, so author time and CI measure the same thing.
# This used to point at a repo-local .gitleaks.toml, which gitleaks ALSO auto-discovers: every
# scan in this repo silently ran under a private rule set, and read as green because that set
# allowlisted the finding rather than because Core's policy was applied
# (dotgibson/dotfiles-core#624). See VENDORING.md, "The gates you run OVER the vendored tree".
secrets: ## Scan the tree + history for committed secrets, under Core's policy
	@command -v gitleaks >/dev/null || { echo "gitleaks not installed — this would run: gitleaks detect --config core/gitleaks.toml"; exit 1; }
	@gitleaks detect --no-banner --redact --config core/gitleaks.toml

# ── the OS capability declaration (Core v5, #663/#667) ────────────────────────
# ONE definition of the schema gates all seven declaring repos: the validator is
# core/scripts/check-capabilities.sh, vendored with Core, so a schema change arrives
# with the next sync instead of needing seven hand-written greps to be updated in
# step. Core's own `make audit` runs the same script over its shipped example and
# sweeps the fleet for these files; this is the local half of that gate.
#
# The glob is guarded because an unmatched glob stays LITERAL in sh — without the
# test this would "validate" a file named `os/*.capabilities` and pass on nothing,
# which is the failure mode a gate must never have.
capabilities: ## Validate os/*.capabilities against Core's schema
	@rc=0; found=0; \
	for f in os/*.capabilities; do \
	  [ -e "$$f" ] || continue; found=1; \
	  core/scripts/check-capabilities.sh "$$f" --packages install/packages.txt || rc=1; \
	done; \
	if [ "$$found" -eq 0 ]; then echo "!! no os/*.capabilities — this repo must declare one (see core/examples/os.capabilities.example)"; rc=1; fi; \
	exit $$rc

