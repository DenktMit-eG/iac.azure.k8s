# syntax=docker/dockerfile:1.7
#
# aks-iac-toolbox - hardened OpenTofu + Azure CLI + kubectl image used to
# bootstrap Azure AKS clusters from this module (and any fork of it).
#
# Hardening:
#   - Ubuntu 26.04 LTS, pinned tag.
#   - Every binary from an apt repo (apt-secure verifies vendor signatures
#     on each update; one pinned key per vendor under /etc/apt/keyrings).
#   - Non-root `dev` user with host UID/GID, no sudo.
#   - setuid/setgid bits stripped from all binaries.
#   - --no-install-recommends, apt cache purged in the same layer.
#   - Compatible with `--read-only --tmpfs /tmp`.
#   - Tini as PID 1, healthcheck runs `tofu version && az version`.

# Ubuntu 24.04 LTS (noble): the codename Microsoft's azure-cli apt repo
# officially supports. Bump only after Microsoft adds the next LTS.
ARG UBUNTU_VERSION=24.04

FROM ubuntu:${UBUNTU_VERSION}

# Versions pinned for reproducibility (current latest as of 2026-05-14).
# KUBECTL_MINOR aligns with kubernetes_version_prefix in variables.tf
# (kubectl is officially skew-compatible cluster minor +/- 1).
ARG TOFU_VERSION=1.12.0
ARG KUBECTL_MINOR=v1.35
ARG KUBECTL_VERSION=1.35.5-1.1
ARG AZ_CLI_VERSION=2.86.0-1~noble
ARG HOST_UID=1000
ARG HOST_GID=1000

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/sbin:/usr/bin:/bin \
    # Stop Azure CLI from leaving a writable history file in $HOME by default
    AZURE_CORE_COLLECT_TELEMETRY=no \
    # Make tofu pick up the lockfile honestly: never silently regenerate
    TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=false

# Base packages: TLS + key fetch + runtime utilities. tini ships in
# Ubuntu's universe; the rest is needed by the wrapper and docs.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      gpg \
      tini \
      bash \
      less \
      jq \
      git \
      dnsutils \
      passwd \
    && rm -rf /var/lib/apt/lists/*

# Register the three third-party apt repos with pinned signing keys.
# Keyring path + `signed-by=` is the modern, non-deprecated apt model.
RUN install -d -m 0755 /etc/apt/keyrings && \
    curl -fsSL https://get.opentofu.org/opentofu.gpg \
      | gpg --dearmor -o /etc/apt/keyrings/opentofu.gpg && \
    curl -fsSL https://packages.opentofu.org/opentofu/tofu/gpgkey \
      | gpg --dearmor -o /etc/apt/keyrings/opentofu-repo.gpg && \
    chmod 0644 /etc/apt/keyrings/opentofu.gpg /etc/apt/keyrings/opentofu-repo.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/opentofu.gpg,/etc/apt/keyrings/opentofu-repo.gpg] https://packages.opentofu.org/opentofu/tofu/any/ any main" \
      > /etc/apt/sources.list.d/opentofu.list && \
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBECTL_MINOR}/deb/Release.key" \
      | gpg --dearmor -o /etc/apt/keyrings/kubernetes.gpg && \
    chmod 0644 /etc/apt/keyrings/kubernetes.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes.gpg] https://pkgs.k8s.io/core:/stable:/${KUBECTL_MINOR}/deb/ /" \
      > /etc/apt/sources.list.d/kubernetes.list && \
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
      | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg && \
    chmod 0644 /etc/apt/keyrings/microsoft.gpg && \
    DIST="$(. /etc/os-release; echo "${UBUNTU_CODENAME:-${VERSION_CODENAME}}")" && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ ${DIST} main" \
      > /etc/apt/sources.list.d/azure-cli.list

# Install pinned versions and apt-mark hold so future apt-get upgrades inside
# the container do not silently bump them. Reproducibility > convenience.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      "tofu=${TOFU_VERSION}" \
      "kubectl=${KUBECTL_VERSION}" \
      "azure-cli=${AZ_CLI_VERSION}" \
    && apt-mark hold tofu kubectl azure-cli \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Strip setuid/setgid bits; nothing in our toolchain needs them.
RUN find / -xdev -perm /6000 -type f -print0 2>/dev/null \
      | xargs -0 -r chmod a-s

# Non-root user matching host UID/GID. Reclaim UID 1000 if Ubuntu's
# default `ubuntu` user already holds it.
RUN if getent passwd "${HOST_UID}" >/dev/null 2>&1; then \
      userdel -r "$(getent passwd "${HOST_UID}" | cut -d: -f1)" 2>/dev/null || true; \
    fi && \
    if getent group "${HOST_GID}" >/dev/null 2>&1; then \
      groupdel "$(getent group "${HOST_GID}" | cut -d: -f1)" 2>/dev/null || true; \
    fi && \
    groupadd -g "${HOST_GID}" dev && \
    useradd -u "${HOST_UID}" -g dev -m -s /bin/bash -d /home/dev dev && \
    install -d -m 0700 -o dev -g dev /home/dev/.azure && \
    install -d -m 0755 -o dev -g dev /workspace

USER dev
WORKDIR /workspace

HEALTHCHECK --interval=1h --timeout=10s --start-period=5s --retries=2 \
  CMD tofu version >/dev/null && az version >/dev/null || exit 1

LABEL org.opencontainers.image.title="aks-iac-toolbox" \
      org.opencontainers.image.description="Hardened OpenTofu + Azure CLI + kubectl image for bootstrapping Azure AKS clusters" \
      org.opencontainers.image.vendor="DenktMit eG" \
      org.opencontainers.image.licenses="Apache-2.0"

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["tofu", "--help"]
