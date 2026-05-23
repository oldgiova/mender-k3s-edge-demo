SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

INPUT ?=

SHELL_SCRIPTS := \
	mender/k8s-update-module \
	mender/build-image.sh \
	mender/convert-overlay/rootfs_overlay/usr/share/mender/modules/v3/k8s-workload \
	mender/convert-overlay/rootfs_overlay/usr/share/mender/inventory/mender-inventory-k8s-app

.PHONY: help build-image lint

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*##"}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

build-image: ## Build the Mender device image  (INPUT=... MENDER_TENANT_TOKEN=...)
	@test -n "$(INPUT)" || { \
	  echo "error: INPUT is required"; \
	  echo "usage: make build-image INPUT=/path/to/raspios-bookworm-arm64-lite.img.xz"; \
	  exit 1; }
	bash mender/build-image.sh "$(INPUT)"

lint: ## Validate YAML syntax and shell script syntax
	@echo "--- YAML ---"
	@find . \( -name '*.yaml' -o -name '*.yml' \) -not -path './.git/*' | sort | \
	  while read -r f; do \
	    python3 -c "import yaml,sys; list(yaml.safe_load_all(open('$$f')))" \
	      && echo "OK  $$f" || exit 1; \
	  done
	@echo "--- shell ---"
	@for f in $(SHELL_SCRIPTS); do sh -n "$$f" && echo "OK  $$f" || exit 1; done
