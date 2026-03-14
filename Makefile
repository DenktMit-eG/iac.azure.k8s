# Front-end over scripts/tofu.sh. Pass extra args via `ARGS="..."`,
# e.g. `make apply ARGS="-auto-approve"`. Override image tag with IMAGE=.

TOFU   ?= ./scripts/tofu.sh
ARGS   ?=
IMAGE  ?= aks-iac-toolbox:local
RUNTIME := $(shell command -v docker 2>/dev/null || command -v podman 2>/dev/null)

.DEFAULT_GOAL := help

.PHONY: help image image-rebuild scan login subscription init fmt validate plan apply destroy output shell

help: ## Show this help.
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ { printf "  %-14s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

image: ## Build the hardened aks-iac-toolbox image (only if missing).
	@if ! $(RUNTIME) image inspect $(IMAGE) >/dev/null 2>&1; then \
	  $(MAKE) image-rebuild; \
	else \
	  echo "image $(IMAGE) already present (use 'make image-rebuild' to force)"; \
	fi

image-rebuild: ## Force-rebuild the aks-iac-toolbox image.
	$(RUNTIME) build \
	  --build-arg HOST_UID=$$(id -u) \
	  --build-arg HOST_GID=$$(id -g) \
	  -t $(IMAGE) \
	  -f docker/Dockerfile \
	  docker

scan: ## Scan the aks-iac-toolbox image with Trivy (requires trivy on host).
	trivy image --severity HIGH,CRITICAL --ignore-unfixed $(IMAGE)

login: ## `az login --use-device-code` inside the container (no browser).
	$(TOFU) az login --use-device-code

subscription: ## Set az default subscription + write subscription_id/tenant_id into terraform.tfvars in place (SUB=<id> required; FORCE=1 to skip the overwrite prompt).
	@test -n "$(SUB)" || (echo "Usage: make subscription SUB=<subscription-id>" >&2; exit 1)
	$(TOFU) az account set --subscription $(SUB)
	$(TOFU) az account show -o table
	@TENANT_ID=$$($(TOFU) az account show --query tenantId -o tsv | tr -d '\r\n'); \
	if [ -z "$$TENANT_ID" ]; then \
	  echo "could not resolve tenant id for $(SUB) - is the subscription accessible?" >&2; \
	  exit 1; \
	fi; \
	if [ -f terraform.tfvars ]; then \
	  echo ""; \
	  echo "==> terraform.tfvars exists. Current subscription/tenant lines:"; \
	  grep -E '^[[:space:]]*#?[[:space:]]*(subscription_id|tenant_id)[[:space:]]*=' terraform.tfvars || echo "  (neither key set)"; \
	  echo ""; \
	  echo "==> Will set in place (every other line preserved):"; \
	  echo "  subscription_id = \"$(SUB)\""; \
	  echo "  tenant_id       = \"$$TENANT_ID\""; \
	  if [ "$(FORCE)" != "1" ]; then \
	    if [ ! -t 0 ]; then \
	      echo "Not a tty and FORCE != 1; refusing to modify." >&2; \
	      exit 1; \
	    fi; \
	    printf "Overwrite subscription_id and tenant_id in place? [y/N] "; \
	    read -r ANSWER; \
	    case "$$ANSWER" in y|Y|yes|YES) ;; *) echo "aborted; terraform.tfvars unchanged."; exit 0 ;; esac; \
	  fi; \
	fi; \
	./scripts/update-tfvars.sh "$(SUB)" "$$TENANT_ID"

init: ## tofu init.
	$(TOFU) tofu init $(ARGS)

fmt: ## tofu fmt -recursive.
	$(TOFU) tofu fmt -recursive

validate: ## tofu validate.
	$(TOFU) tofu validate $(ARGS)

plan: ## tofu plan.
	$(TOFU) tofu plan $(ARGS)

apply: ## tofu apply (will prompt unless ARGS includes -auto-approve).
	$(TOFU) tofu apply $(ARGS)

destroy: ## tofu destroy.
	$(TOFU) tofu destroy $(ARGS)

output: ## Print outputs (use ARGS="-raw <name>" for one).
	$(TOFU) tofu output $(ARGS)

shell: ## Drop into a shell inside the aks-iac-toolbox image (for debugging).
	$(TOFU) bash
