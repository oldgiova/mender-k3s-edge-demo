SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

INPUT             ?=
DEVICE_IP         ?=
DEVICE_USER       ?= pi
MENDER_DEVICE_TYPE ?= raspberrypi4_64
ARTIFACT_NAME     ?= golden-k3s-$(shell date +%Y%m%d)
SSH_KEY             ?= $(HOME)/.ssh/id_ed25519.pub
MENDER_SERVER_URL   ?=
MENDER_TENANT_TOKEN ?=
K3S_VERSION         ?=
ENABLE_SSH_ACCESS   ?= false
DEVICE_HOSTNAME     ?=

SHELL_SCRIPTS := \
	mender/k8s-update-module \
	mender/build-image.sh \
	mender/setup-device.sh \
	mender/customize-image.sh \
	mender/convert-overlay/rootfs_overlay/usr/share/mender/modules/v3/k8s-workload \
	mender/convert-overlay/rootfs_overlay/usr/share/mender/inventory/mender-inventory-k8s-app

.PHONY: help build-image setup-device customize-image snapshot-image lint

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*##"}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

build-image: ## Build the Mender device image  (INPUT=... MENDER_TENANT_TOKEN=...)
	@test -n "$(INPUT)" || { \
	  echo "error: INPUT is required"; \
	  echo "usage: make build-image INPUT=/path/to/raspios-bookworm-arm64-lite.img.xz"; \
	  exit 1; }
	bash mender/build-image.sh "$(INPUT)"

setup-device: ## Install update module and inventory script on this device (run on the Pi)
	bash mender/setup-device.sh

customize-image: ## Patch a Mender image: user, SSH key, mender.conf, k3s (INPUT=... SSH_KEY=... MENDER_SERVER_URL=... MENDER_TENANT_TOKEN=... K3S_VERSION=...)
	@test -n "$(INPUT)" || { \
	  echo "error: INPUT is required"; \
	  echo "usage: make customize-image INPUT=/path/to/mender-image.img.xz"; \
	  exit 1; }
	@MENDER_SERVER_URL="$(MENDER_SERVER_URL)" \
	MENDER_TENANT_TOKEN="$(MENDER_TENANT_TOKEN)" \
	K3S_VERSION="$(K3S_VERSION)" \
	ENABLE_SSH_ACCESS="$(ENABLE_SSH_ACCESS)" \
	DEVICE_HOSTNAME="$(DEVICE_HOSTNAME)" \
	bash mender/customize-image.sh "$(INPUT)" "$(DEVICE_USER)" "$(SSH_KEY)"

snapshot-image: ## Create golden rootfs artifact from a running device (DEVICE_IP=...)
	@test -n "$(DEVICE_IP)" || { echo "error: DEVICE_IP is required"; exit 1; }
	@which mender-artifact >/dev/null 2>&1 || { \
	  echo "error: mender-artifact not installed — see https://docs.mender.io/downloads"; \
	  exit 1; }
	mkdir -p output
	mender-artifact write rootfs-image \
	    -f "ssh://$(DEVICE_USER)@$(DEVICE_IP)" \
	    -n "$(ARTIFACT_NAME)" \
	    --software-version "$(ARTIFACT_NAME)" \
	    -c "$(MENDER_DEVICE_TYPE)" \
	    -o "output/$(ARTIFACT_NAME).mender"
	@echo "Artifact: output/$(ARTIFACT_NAME).mender"

lint: ## Validate YAML syntax and shell script syntax
	@echo "--- YAML ---"
	@find . \( -name '*.yaml' -o -name '*.yml' \) -not -path './.git/*' | sort | \
	  while read -r f; do \
	    python3 -c "import yaml,sys; list(yaml.safe_load_all(open('$$f')))" \
	      && echo "OK  $$f" || exit 1; \
	  done
	@echo "--- shell ---"
	@for f in $(SHELL_SCRIPTS); do sh -n "$$f" && echo "OK  $$f" || exit 1; done
