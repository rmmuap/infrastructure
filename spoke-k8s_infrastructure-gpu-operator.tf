locals {
  gpu-operator_repo_fqdn = "git@github.com:${var.GITHUB_ORG}/${var.MANIFESTS_INFRASTRUCTURE_REPO_NAME}.git"
}

resource "azurerm_kubernetes_flux_configuration" "gpu-operator" {
  count                             = var.GPU_NODE_POOL ? 1 : 0
  name                              = "gpu-operator"
  cluster_id                        = azurerm_kubernetes_cluster.kubernetes_cluster.id
  namespace                         = "cluster-config"
  scope                             = "cluster"
  continuous_reconciliation_enabled = true
  git_repository {
    url                      = local.gpu-operator_repo_fqdn
    reference_type           = "branch"
    reference_value          = "main"
    sync_interval_in_seconds = 60
    ssh_private_key_base64   = base64encode(var.MANIFESTS_INFRASTRUCTURE_SSH_PRIVATE_KEY)
  }
  kustomizations {
    name                       = "gpu-operator"
    recreating_enabled         = true
    garbage_collection_enabled = true
    sync_interval_in_seconds   = 60
    path                       = "./gpu-operator"
  }
  depends_on = [
    azurerm_kubernetes_cluster_extension.flux_extension
  ]
}
