#!/usr/bin/env bash
# update-tfvars.sh - set subscription_id and tenant_id in ./terraform.tfvars.
#
# - If ./terraform.tfvars does not exist, copies it from ./terraform.tfvars.example
#   first so the operator inherits the commented overrides documented there.
# - Replaces existing subscription_id / tenant_id lines (commented or live) in
#   place. Appends them if absent. Other lines are preserved verbatim, including
#   any hand-added overrides (prefix, node_count, tags, …).
#
# Usage: update-tfvars.sh <subscription-id> <tenant-id>

set -euo pipefail

SUB="${1:?missing subscription id}"
TENANT="${2:?missing tenant id}"

TFVARS=terraform.tfvars
EXAMPLE=terraform.tfvars.example

if [[ ! -f "$TFVARS" ]]; then
  if [[ ! -f "$EXAMPLE" ]]; then
    echo "$EXAMPLE missing; cannot create $TFVARS" >&2
    exit 1
  fi
  cp "$EXAMPLE" "$TFVARS"
  echo "Created $TFVARS from $EXAMPLE."
fi

# Set `<key> = "<val>"` in $TFVARS. The label argument is the left-hand side
# rendered verbatim (so callers can pad it to align with sibling keys, matching
# the convention in terraform.tfvars.example).
#   1. If an uncommented line for the key exists, replace it.
#   2. Else if a commented line exists, replace it with the live form.
#   3. Else append at the end.
set_var() {
  local key="$1" label="$2" val="$3" tmp
  tmp=$(mktemp)
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$TFVARS"; then
    awk -v label="$label" -v val="$val" -v pat="^[[:space:]]*${key}[[:space:]]*=" '
      $0 ~ pat && !done { print label " = \"" val "\""; done=1; next }
      { print }
    ' "$TFVARS" > "$tmp"
  elif grep -qE "^[[:space:]]*#[[:space:]]*${key}[[:space:]]*=" "$TFVARS"; then
    awk -v label="$label" -v val="$val" -v pat="^[[:space:]]*#[[:space:]]*${key}[[:space:]]*=" '
      $0 ~ pat && !done { print label " = \"" val "\""; done=1; next }
      { print }
    ' "$TFVARS" > "$tmp"
  else
    cat "$TFVARS" > "$tmp"
    printf '%s = "%s"\n' "$label" "$val" >> "$tmp"
  fi
  mv "$tmp" "$TFVARS"
}

# `tenant_id` is padded to align with `subscription_id` when the two land on
# adjacent lines, matching terraform.tfvars.example.
set_var subscription_id "subscription_id" "$SUB"
set_var tenant_id       "tenant_id      " "$TENANT"

echo "Set subscription_id and tenant_id in $TFVARS."
