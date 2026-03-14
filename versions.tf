# Pin both the CLI and the providers so a fresh checkout reproduces the
# same plan today and next year.
terraform {
  # Minimum tofu/terraform CLI version. Older binaries reject the config
  # before parsing so we never silently miss newer HCL features.
  required_version = ">= 1.8"

  required_providers {
    # azurerm 4.65+ is required: the federated_identity_credential resource
    # renamed `parent_id` to `user_assigned_identity_id` in that release and
    # main.tf uses the new name. `~> 4.65` accepts any 4.65.x or higher 4.x
    # patch but blocks the 5.0 jump, which can be breaking.
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.65"
    }
  }
}

# Runtime configuration for the azurerm provider once it has been
# downloaded. Both ids accept null so the provider can fall back to ARM_*
# environment variables or the active `az` session bind-mounted by
# scripts/tofu.sh. `features {}` is a required (empty) block that gates
# opt-in provider behaviours (key vault soft-delete handling, etc.).
provider "azurerm" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
  features {}
}
