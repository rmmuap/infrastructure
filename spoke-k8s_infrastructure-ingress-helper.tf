resource "kubernetes_namespace" "ingress-helper" {
  depends_on = [
    azurerm_kubernetes_cluster.kubernetes_cluster
  ]
  metadata {
    name = "ingress-helper"
    labels = {
      name = "ingress-helper"
    }
  }
}

resource "kubernetes_secret" "ingress-helper_fortiweb_login_secret" {
  count = var.APPLICATION_DOCS ? 1 : 0
  metadata {
    name      = "fortiweb-login-secret"
    namespace = kubernetes_namespace.ingress-helper.metadata[0].name
  }
  data = {
    username = var.HUB_NVA_USERNAME
    password = var.HUB_NVA_PASSWORD
  }
  type = "Opaque"
}
