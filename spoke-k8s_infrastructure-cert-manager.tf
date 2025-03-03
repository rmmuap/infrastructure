resource "azurerm_user_assigned_identity" "cert-manager" {
  name                = "cert-manager"
  resource_group_name = azurerm_resource_group.azure_resource_group.name
  location            = azurerm_resource_group.azure_resource_group.location
}

data "azurerm_user_assigned_identity" "cert_manager_data" {
  name                = azurerm_user_assigned_identity.cert-manager.name
  resource_group_name = azurerm_resource_group.azure_resource_group.name
  depends_on          = [azurerm_user_assigned_identity.cert-manager]
}

resource "azurerm_role_assignment" "cert-manager_role_assignment" {
  principal_id         = azurerm_user_assigned_identity.cert-manager.principal_id
  role_definition_name = "DNS Zone Contributor"
  scope                = azurerm_dns_zone.dns_zone.id
}

resource "azurerm_federated_identity_credential" "cert-manager_federated_identity_credential" {
  name                = "cert-manager_federated_identity_credential"
  resource_group_name = azurerm_resource_group.azure_resource_group.name
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.kubernetes_cluster.oidc_issuer_url
  parent_id           = azurerm_user_assigned_identity.cert-manager.id
  subject             = "system:serviceaccount:cert-manager:cert-manager"
}

resource "kubernetes_namespace" "cert-manager" {
  depends_on = [
    azurerm_kubernetes_cluster.kubernetes_cluster
  ]
  metadata {
    name = "cert-manager"
    labels = {
      name = "cert-manager"
    }
  }
}

resource "kubernetes_secret" "cert-manager_fortiweb_login_secret" {
  metadata {
    name      = "fortiweb-login-secret"
    namespace = kubernetes_namespace.cert-manager.metadata[0].name
  }
  data = {
    username = var.HUB_NVA_USERNAME
    password = var.HUB_NVA_PASSWORD
  }
  type = "Opaque"
}

resource "kubernetes_secret" "clusterissuer" {
  metadata {
    name      = "clusterissuer"
    namespace = kubernetes_namespace.cert-manager.metadata[0].name
  }
  data = {
    server            = var.LETSENCRYPT_URL
    email             = var.OWNER_EMAIL
    resourceGroupName = azurerm_resource_group.azure_resource_group.name
    subscriptionID    = var.ARM_SUBSCRIPTION_ID
    hostedZoneName    = var.DNS_ZONE
    clientID          = data.azurerm_user_assigned_identity.cert_manager_data.client_id
    checksum          = md5(
      jsonencode({
        server            = var.LETSENCRYPT_URL
        email             = var.OWNER_EMAIL
        resourceGroupName = azurerm_resource_group.azure_resource_group.name
        subscriptionID    = var.ARM_SUBSCRIPTION_ID
        hostedZoneName    = var.DNS_ZONE
        clientID          = data.azurerm_user_assigned_identity.cert_manager_data.client_id
      })
    )
  }
  type = "Opaque"
}
