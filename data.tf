data "azurerm_public_ip" "hub-nva-management_public_ip" {
  count               = var.MANAGEMENT_PUBLIC_IP ? 1 : 0
  name                = azurerm_public_ip.hub-nva-management_public_ip[0].name
  resource_group_name = azurerm_resource_group.azure_resource_group.name
}
