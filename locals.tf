locals {
  vm-image = {
    "fortiweb" = {
      publisher       = "fortinet"
      offer           = "fortinet_fortiweb-vm_v5"
      size            = "Standard_F16s_v2"
      size-dev        = "Standard_D4as_v5"
      version         = "latest"
      sku             = "fortinet_fw-vm_payg_v2"
      management-port = "443"
      terms           = true
    },
    "aks" = {
      version      = "latest"
      terms        = false
      offer        = ""
      sku          = ""
      publisher    = ""
      size         = "Standard_E4s_v3"
      size-dev     = "Standard_B4ms"
      cpu-size     = "Standard_E4s_v3"
      cpu-size-dev = "Standard_B4ms"
      gpu-size     = "Standard_NC24s_v3"
      #gpu-size    = "Standard_NC24ads_A100_v4"
      #gpu-size    = "Standard_NC4as_T4_v3"
      gpu-size-dev = "Standard_NC4as_T4_v3"
    }
  }
}
