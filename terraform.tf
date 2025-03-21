terraform {
  required_version = ">=1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.24.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.7.1"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "4.0.6"
    }
    http = {
      source  = "hashicorp/http"
      version = "3.4.5"
    }
    null = {
      source  = "hashicorp/null"
      version = "3.2.3"
    }
    local = {
      source  = "hashicorp/local"
      version = "2.5.2"
    }
    github = {
      source  = "integrations/github"
      version = "6.6.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "2.3.4"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.36.0"
    }
    htpasswd = {
      source  = "loafoe/htpasswd"
      version = "1.2.1"
    }
    flux = {
      source  = "fluxcd/flux"
      version = "1.5.1"
    }
  }
  backend "azurerm" {}
}

data "azurerm_subscription" "current" {
}

data "azurerm_client_config" "current" {
}

provider "azurerm" {
  features {
    api_management {
      purge_soft_delete_on_destroy = true
      recover_soft_deleted         = false
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

provider "random" {}
provider "tls" {}
provider "http" {}
provider "htpasswd" {}
provider "local" {}
provider "github" {
  owner = var.GITHUB_ORG
  token = var.GITHUB_TOKEN
}
provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.kubernetes_cluster.kube_config[0].host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.kubernetes_cluster.kube_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.kubernetes_cluster.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.kubernetes_cluster.kube_config[0].cluster_ca_certificate)
}

provider "flux" {
  kubernetes = {
    host                   = azurerm_kubernetes_cluster.kubernetes_cluster.kube_config[0].host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.kubernetes_cluster.kube_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.kubernetes_cluster.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.kubernetes_cluster.kube_config[0].cluster_ca_certificate)
  }
}
