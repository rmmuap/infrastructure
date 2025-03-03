data "azurerm_public_ip" "hub-nva-vip_video_public_ip" {
  count               = var.APPLICATION_VIDEO ? 1 : 0
  name                = azurerm_public_ip.hub-nva-vip_video_public_ip[0].name
  resource_group_name = azurerm_resource_group.azure_resource_group.name
}

resource "azurerm_public_ip" "hub-nva-vip_video_public_ip" {
  count               = var.APPLICATION_VIDEO ? 1 : 0
  name                = "hub-nva-vip_video_public_ip"
  location            = azurerm_resource_group.azure_resource_group.location
  resource_group_name = azurerm_resource_group.azure_resource_group.name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "${azurerm_resource_group.azure_resource_group.name}-video"
}

resource "kubernetes_namespace" "video" {
  count = var.APPLICATION_VIDEO ? 1 : 0
  depends_on = [
    azurerm_kubernetes_cluster.kubernetes_cluster
  ]
  metadata {
    name = "video"
    labels = {
      name = "video"
    }
  }
}

resource "kubernetes_secret" "video_fortiweb_login_secret" {
  count = var.APPLICATION_VIDEO ? 1 : 0
  metadata {
    name      = "fortiweb-login-secret"
    namespace = kubernetes_namespace.video[0].metadata[0].name
  }
  data = {
    username = var.HUB_NVA_USERNAME
    password = var.HUB_NVA_PASSWORD
  }
  type = "Opaque"
}

locals {
  video_manifest_repo_fqdn = "git@github.com:${var.GITHUB_ORG}/${var.MANIFESTS_APPLICATIONS_REPO_NAME}.git"
}

resource "azurerm_kubernetes_flux_configuration" "video" {
  count                             = var.APPLICATION_VIDEO ? 1 : 0
  name                              = "video"
  cluster_id                        = azurerm_kubernetes_cluster.kubernetes_cluster.id
  namespace                         = "cluster-config"
  scope                             = "cluster"
  continuous_reconciliation_enabled = true
  git_repository {
    url                      = local.video_manifest_repo_fqdn
    reference_type           = "branch"
    reference_value          = "video-version"
    sync_interval_in_seconds = 60
    ssh_private_key_base64   = base64encode(var.MANIFESTS_APPLICATIONS_SSH_PRIVATE_KEY)
  }
  kustomizations {
    name                       = "video"
    recreating_enabled         = true
    garbage_collection_enabled = true
    path                       = "./video"
    sync_interval_in_seconds   = 60
  }
  depends_on = [
    azurerm_kubernetes_flux_configuration.infrastructure
  ]
}
