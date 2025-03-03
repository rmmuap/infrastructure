resource "kubernetes_namespace" "lacework-agent" {
  depends_on = [
    azurerm_kubernetes_cluster.kubernetes_cluster
  ]
  metadata {
    name = "lacework-agent"
    labels = {
      name = "lacework-agent"
    }
  }
}

resource "kubernetes_secret" "lacework_agent_token" {
  metadata {
    name      = "lacework-agent-token"
    namespace = kubernetes_namespace.lacework-agent.metadata[0].name
  }
  data = {
    "config.json" = jsonencode({
      tokens = {
        AccessToken = var.LW_AGENT_TOKEN
      },
      serverurl = "https://api.lacework.net",
      tags = {
        Env               = "k8s",
        KubernetesCluster = azurerm_kubernetes_cluster.kubernetes_cluster.name
      }
    }),
    "syscall_config.yaml" = ""
  }
}
