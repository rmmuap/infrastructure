resource "azurerm_public_ip" "hub-nva-management_public_ip" {
  count               = var.MANAGEMENT_PUBLIC_IP ? 1 : 0
  name                = "hub-nva-management_public_ip"
  location            = azurerm_resource_group.azure_resource_group.location
  resource_group_name = azurerm_resource_group.azure_resource_group.name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "${azurerm_resource_group.azure_resource_group.name}-management"
}

resource "azurerm_dns_cname_record" "hub-nva" {
  count               = var.MANAGEMENT_PUBLIC_IP ? 1 : 0
  name                = "hub-nva"
  zone_name           = azurerm_dns_zone.dns_zone.name
  resource_group_name = azurerm_resource_group.azure_resource_group.name
  ttl                 = 300
  record              = data.azurerm_public_ip.hub-nva-management_public_ip[0].fqdn
}

resource "azurerm_availability_set" "hub-nva_availability_set" {
  location                     = azurerm_resource_group.azure_resource_group.location
  resource_group_name          = azurerm_resource_group.azure_resource_group.name
  name                         = "hub-nva_availability_set"
  platform_fault_domain_count  = 2
  platform_update_domain_count = 2
}

locals {
  ip_configurations = [
    {
      name                          = "hub-nva-external-management_ip_configuration"
      primary                       = true
      private_ip_address_allocation = "Static"
      private_ip_address            = var.hub-nva-management-ip
      subnet_id                     = azurerm_subnet.hub-external_subnet.id
      public_ip_address_id          = var.MANAGEMENT_PUBLIC_IP ? (length(azurerm_public_ip.hub-nva-management_public_ip) > 0 ? azurerm_public_ip.hub-nva-management_public_ip[0].id : null) : null
      condition                     = true
    },
    {
      name                          = "hub-nva-external-vip-docs_configuration"
      primary                       = false
      private_ip_address_allocation = "Static"
      private_ip_address            = var.hub-nva-vip-docs
      subnet_id                     = azurerm_subnet.hub-external_subnet.id
      public_ip_address_id          = length(azurerm_public_ip.hub-nva-vip_docs_public_ip) > 0 ? azurerm_public_ip.hub-nva-vip_docs_public_ip[0].id : null
      condition                     = var.APPLICATION_DOCS
    },
    {
      name                          = "hub-nva-external-vip-dvwa_configuration"
      primary                       = false
      private_ip_address_allocation = "Static"
      private_ip_address            = var.hub-nva-vip-dvwa
      subnet_id                     = azurerm_subnet.hub-external_subnet.id
      public_ip_address_id          = length(azurerm_public_ip.hub-nva-vip_dvwa_public_ip) > 0 ? azurerm_public_ip.hub-nva-vip_dvwa_public_ip[0].id : null
      condition                     = var.APPLICATION_DVWA
    },
    {
      name                          = "hub-nva-external-vip-ollama_configuration"
      primary                       = false
      private_ip_address_allocation = "Static"
      private_ip_address            = var.hub-nva-vip-ollama
      subnet_id                     = azurerm_subnet.hub-external_subnet.id
      public_ip_address_id          = length(azurerm_public_ip.hub-nva-vip_ollama_public_ip) > 0 ? azurerm_public_ip.hub-nva-vip_ollama_public_ip[0].id : null
      condition                     = var.APPLICATION_OLLAMA
    },
    {
      name                          = "hub-nva-external-vip-video_configuration"
      primary                       = false
      private_ip_address_allocation = "Static"
      private_ip_address            = var.hub-nva-vip-video
      subnet_id                     = azurerm_subnet.hub-external_subnet.id
      public_ip_address_id          = length(azurerm_public_ip.hub-nva-vip_video_public_ip) > 0 ? azurerm_public_ip.hub-nva-vip_video_public_ip[0].id : null
      condition                     = var.APPLICATION_VIDEO
    }
  ]
}

# Resource Definition
resource "azurerm_network_interface" "hub-nva-external_network_interface" {
  name                           = "hub-nva-external_network_interface"
  location                       = azurerm_resource_group.azure_resource_group.location
  resource_group_name            = azurerm_resource_group.azure_resource_group.name
  accelerated_networking_enabled = true

  dynamic "ip_configuration" {
    for_each = [for ip in local.ip_configurations : ip if ip.condition]

    content {
      name                          = ip_configuration.value.name
      primary                       = lookup(ip_configuration.value, "primary", false)
      private_ip_address_allocation = ip_configuration.value.private_ip_address_allocation
      private_ip_address            = ip_configuration.value.private_ip_address
      subnet_id                     = ip_configuration.value.subnet_id
      public_ip_address_id          = ip_configuration.value.public_ip_address_id
    }
  }
}

resource "azurerm_network_interface" "hub-nva-internal_network_interface" {
  name                           = "hub-nva-internal_network_interface"
  location                       = azurerm_resource_group.azure_resource_group.location
  resource_group_name            = azurerm_resource_group.azure_resource_group.name
  accelerated_networking_enabled = true
  ip_forwarding_enabled          = true #checkov:skip=CKV_AZURE_118:Fortigate NIC needs IP forwarding.
  ip_configuration {
    name                          = "hub-nva-internal_ip_configuration"
    private_ip_address_allocation = "Static"
    private_ip_address            = var.hub-nva-gateway
    subnet_id                     = azurerm_subnet.hub-internal_subnet.id
  }
}

resource "azurerm_linux_virtual_machine" "hub-nva_virtual_machine" {
  #checkov:skip=CKV_AZURE_178: Allow Fortigate to present HTTPS login UI instead of SSH
  #checkov:skip=CKV_AZURE_149: Allow Fortigate to present HTTPS login UI instead of SSH
  #checkov:skip=CKV_AZURE_1: Allow Fortigate to present HTTPS login UI instead of SSH
  #depends_on                      = [null_resource.marketplace_agreement, azurerm_managed_disk.log_disk]
  depends_on                      = [null_resource.marketplace_agreement]
  name                            = "hub-nva_virtual_machine"
  computer_name                   = "hub-nva"
  availability_set_id             = azurerm_availability_set.hub-nva_availability_set.id
  admin_username                  = var.HUB_NVA_USERNAME
  disable_password_authentication = false #tfsec:ignore:AVD-AZU-0039
  admin_password                  = var.HUB_NVA_PASSWORD
  location                        = azurerm_resource_group.azure_resource_group.location
  resource_group_name             = azurerm_resource_group.azure_resource_group.name
  network_interface_ids           = [azurerm_network_interface.hub-nva-external_network_interface.id, azurerm_network_interface.hub-nva-internal_network_interface.id]
  size                            = var.PRODUCTION_ENVIRONMENT ? local.vm-image[var.hub-nva-image].size : local.vm-image[var.hub-nva-image].size-dev
  allow_extension_operations      = false

  identity {
    type = "SystemAssigned"
  }
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = var.PRODUCTION_ENVIRONMENT ? "Premium_LRS" : "Standard_LRS"
    #disk_size_gb = var.PRODUCTION_ENVIRONMENT ? 256 : 128
  }
  plan {
    name      = local.vm-image[var.hub-nva-image].sku
    product   = local.vm-image[var.hub-nva-image].offer
    publisher = local.vm-image[var.hub-nva-image].publisher
  }
  source_image_reference {
    offer     = local.vm-image[var.hub-nva-image].offer
    publisher = local.vm-image[var.hub-nva-image].publisher
    sku       = local.vm-image[var.hub-nva-image].sku
    version   = "latest"
  }
  custom_data = base64encode(
    templatefile("cloud-init/${var.hub-nva-image}.conf",
      {
        VAR-config-system-global-admin-sport     = local.vm-image[var.hub-nva-image].management-port
        VAR-hub-external-subnet-gateway          = var.hub-external-subnet-gateway
        VAR-spoke-check-internet-up-ip           = var.spoke-check-internet-up-ip
        VAR-spoke-default-gateway                = cidrhost(var.hub-internal-subnet_prefix, 1)
        VAR-spoke-virtual-network_address_prefix = var.spoke-virtual-network_address_prefix
        VAR-spoke-virtual-network_subnet         = cidrhost(var.spoke-virtual-network_address_prefix, 0)
        VAR-spoke-virtual-network_netmask        = cidrnetmask(var.spoke-virtual-network_address_prefix)
        VAR-spoke-aks-node-ip                    = var.spoke-aks-node-ip
        VAR-hub-nva-vip-docs                     = var.hub-nva-vip-docs
        VAR-hub-nva-vip-ollama                   = var.hub-nva-vip-ollama
        VAR-hub-nva-vip-video                    = var.hub-nva-vip-video
        VAR-hub-nva-vip-dvwa                     = var.hub-nva-vip-dvwa
        VAR-HUB_NVA_USERNAME                     = var.HUB_NVA_USERNAME
        VAR-CERTIFICATE                          = tls_self_signed_cert.self_signed_cert.cert_pem
        VAR-PRIVATEKEY                           = tls_private_key.private_key.private_key_pem
        VAR-fwb_license_file                     = ""
        VAR-fwb_license_fortiflex                = ""
        VAR-spoke-aks-network                    = var.spoke-aks-subnet_prefix
      }
    )
  )
}

#resource "azurerm_managed_disk" "log_disk" {
#  name                 = "hub-nva-log_disk"
#  location             = azurerm_resource_group.azure_resource_group.location
#  resource_group_name  = azurerm_resource_group.azure_resource_group.name
#  storage_account_type = "Standard_LRS"
#  create_option        = "Empty"
#  disk_size_gb         = var.PRODUCTION_ENVIRONMENT ? 128 : 36
#}

#resource "azurerm_virtual_machine_data_disk_attachment" "log_disk" {
#  managed_disk_id    = azurerm_managed_disk.log_disk.id
#  virtual_machine_id = azurerm_linux_virtual_machine.hub-nva_virtual_machine.id
#  lun                = "0"
#  caching            = "ReadWrite"
#}
