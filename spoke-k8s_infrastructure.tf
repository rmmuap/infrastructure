locals {
  infrastructure_repo_fqdn = "git@github.com:${var.GITHUB_ORG}/${var.MANIFESTS_INFRASTRUCTURE_REPO_NAME}.git"
}

resource "azurerm_kubernetes_flux_configuration" "infrastructure" {
  name                              = "infrastructure"
  cluster_id                        = azurerm_kubernetes_cluster.kubernetes_cluster.id
  namespace                         = "cluster-config"
  scope                             = "cluster"
  continuous_reconciliation_enabled = true
  git_repository {
    url                      = local.infrastructure_repo_fqdn
    reference_type           = "branch"
    reference_value          = "main"
    sync_interval_in_seconds = 60
    ssh_private_key_base64   = base64encode(var.MANIFESTS_INFRASTRUCTURE_SSH_PRIVATE_KEY)
  }
  kustomizations {
    name                       = "infrastructure"
    recreating_enabled         = true
    garbage_collection_enabled = true
    sync_interval_in_seconds   = 60
  }
  kustomizations {
    name                       = "cert-manager-clusterissuer"
    recreating_enabled         = true
    garbage_collection_enabled = true
    sync_interval_in_seconds   = 60
    path                       = "./cert-manager-clusterissuer"
    depends_on                 = ["infrastructure"]
  }
  depends_on = [
    azurerm_kubernetes_cluster_extension.flux_extension,
    kubernetes_namespace.lacework-agent
  ]
}
