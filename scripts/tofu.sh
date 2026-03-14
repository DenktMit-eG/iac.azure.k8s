#!/usr/bin/env bash
# =============================================================================
# scripts/tofu.sh - run the AKS tools container against this module
# =============================================================================
#
# The single host-side entry point for everything in this module. Wraps a
# docker/podman invocation so the developer never needs OpenTofu, Azure CLI,
# or kubectl installed locally. The Makefile targets and the docs all
# funnel through here.
#
# -----------------------------------------------------------------------------
# USAGE
# -----------------------------------------------------------------------------
#
#   ./scripts/tofu.sh plan                  # bare tofu subcommand (prepended below)
#   ./scripts/tofu.sh tofu plan             # explicit, equivalent
#   ./scripts/tofu.sh az account show       # any binary bundled in the image
#   ./scripts/tofu.sh kubectl get nodes
#   ./scripts/tofu.sh jq . terraform.tfstate
#   ./scripts/tofu.sh bash                  # interactive shell inside the container
#
# The Makefile wraps the most common paths (`make plan`, `make apply`,
# `make login`, `make subscription`) - see `make help`.
#
# -----------------------------------------------------------------------------
# BIND MOUNTS
# -----------------------------------------------------------------------------
#
#   host                          container         purpose
#   ------------------------      -----------       --------------------------
#   $MODULE_DIR (this repo)  -->  /workspace        OpenTofu working directory
#   ~/.azure                 -->  /home/dev/.azure  shared `az login` session
#   ~/.kube                  -->  /home/dev/.kube   shared kubeconfigs
#
# Both ~/.azure and ~/.kube are bind-mounted *read-write*. That means:
#   - `make login` (`az login --use-device-code` inside) persists on the host.
#   - `az aks get-credentials --file ~/.kube/config-acc` writes a kubeconfig
#     that the host's own kubectl can immediately `KUBECONFIG=` against.
#
# The image runs as a non-root user whose UID/GID match the host (set at
# build time via --build-arg HOST_UID / HOST_GID). Files written into
# /workspace from the container end up owned by the host user, not root.
#
# -----------------------------------------------------------------------------
# ENVIRONMENT FORWARDED INTO THE CONTAINER
# -----------------------------------------------------------------------------
#
# Variables whose names match any of these prefixes are passed through:
#
#   ARM_*       - azurerm provider auth (ARM_SUBSCRIPTION_ID, ARM_USE_OIDC, ...)
#   TF_VAR_*    - tofu input variables via env (TF_VAR_node_count, ...)
#   AZURE_*     - Azure CLI overrides (AZURE_CORE_OUTPUT, ...)
#   TOFU_*      - tofu runtime flags (TOFU_LOG, TOFU_CLI_CONFIG_FILE, ...)
#   KUBECONFIG  - target kubeconfig path inside the container
#
# Nothing else crosses the boundary; secrets in unrelated env vars stay on
# the host.
#
# -----------------------------------------------------------------------------
# CONTAINER HARDENING (the `docker run` flags below)
# -----------------------------------------------------------------------------
#
#   --read-only                  - rootfs is immutable; only /workspace and
#                                  /home/dev/{.azure,.kube} (bind mounts) plus
#                                  /tmp (tmpfs) are writable.
#   --tmpfs /tmp:exec,size=128m  - small writable scratch; `exec` because the
#                                  azurerm provider unpacks a plugin into here.
#   --cap-drop=ALL               - drop every Linux capability; tofu and az do
#                                  not need any of them.
#   --security-opt no-new-privileges
#                                - block setuid escalation paths even if a
#                                  binary somehow regained an s-bit.
#
# Combined with the Dockerfile's "strip setuid bits" step and non-root user,
# the runtime surface is tight. Override the image with `TOOLS_IMAGE=...`
# only when you know what you are weakening.
#
# -----------------------------------------------------------------------------
# AUTO-BUILD
# -----------------------------------------------------------------------------
#
# If the target image is not present locally, it is built from
# `docker/Dockerfile` automatically, passing the host UID/GID as build args.
# `make image-rebuild` forces a clean rebuild without first removing the
# image.
#
# -----------------------------------------------------------------------------
# OVERRIDES
# -----------------------------------------------------------------------------
#
#   TOOLS_IMAGE=aks-iac-toolbox:dev     use a different image tag
#   RUNTIME picks docker, then podman    no override - whichever is on PATH
#
# To change the bundled OpenTofu / kubectl / Azure CLI versions, edit the
# ARG defaults in `docker/Dockerfile` and rebuild with `make image-rebuild`.
#
# -----------------------------------------------------------------------------
# REQUIREMENTS ON THE HOST
# -----------------------------------------------------------------------------
#
#   - docker or podman on PATH
#   - bash 4+
#   - a regular user (the wrapper uses `id -u` / `id -g` to match perms)
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
MODULE_DIR="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"

IMAGE="${TOOLS_IMAGE:-aks-iac-toolbox:local}"

if command -v docker >/dev/null 2>&1; then
  RUNTIME="docker"
elif command -v podman >/dev/null 2>&1; then
  RUNTIME="podman"
else
  echo "scripts/tofu.sh: neither 'docker' nor 'podman' found on PATH" >&2
  exit 127
fi

if ! "$RUNTIME" image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "scripts/tofu.sh: building $IMAGE..." >&2
  "$RUNTIME" build \
    --build-arg "HOST_UID=$(id -u)" \
    --build-arg "HOST_GID=$(id -g)" \
    -t "$IMAGE" \
    -f "$MODULE_DIR/docker/Dockerfile" \
    "$MODULE_DIR/docker"
fi

# Forward selected env vars without listing them. Anything that does not
# match one of these prefixes stays on the host - see header for the list.
ENV_ARGS=()
while IFS='=' read -r name _; do
  case "$name" in
  ARM_* | TF_VAR_* | AZURE_* | TOFU_* | KUBECONFIG) ENV_ARGS+=(-e "$name") ;;
  esac
done < <(env)

# Only give the container a tty when the caller has one. Without this guard
# `docker run -it` would fail under non-interactive shells (scripts,
# redirected output, etc.) and would emit control sequences into captured
# logs.
TTY_ARGS=()
if [ -t 0 ] && [ -t 1 ]; then
  TTY_ARGS+=(-it)
fi

# Ensure the bind-mount targets exist on the host. Without this, the first
# `az login` in a fresh checkout would fail because the source path is
# missing (docker creates host paths as root, which we want to avoid).
mkdir -p "$HOME/.azure" "$HOME/.kube"

# Convenience: when the first argument is a tofu subcommand (with no `tofu`
# in front), prepend `tofu` so `./scripts/tofu.sh plan` works. Anything else
# (`az ...`, `kubectl ...`, `bash`, `jq ...`) is passed through verbatim.
case "${1:-}" in
init | plan | apply | destroy | fmt | validate | output | console | state | providers | workspace | graph | import | refresh | show | taint | untaint | test | version | "")
  set -- tofu "$@"
  ;;
esac

exec "$RUNTIME" run --rm \
  "${TTY_ARGS[@]}" \
  --read-only \
  --tmpfs /tmp:exec,size=128m \
  --cap-drop=ALL \
  --security-opt no-new-privileges \
  -v "$MODULE_DIR":/workspace \
  -v "$HOME/.azure":/home/dev/.azure \
  -v "$HOME/.kube":/home/dev/.kube \
  -w /workspace \
  "${ENV_ARGS[@]}" \
  "$IMAGE" \
  "$@"
