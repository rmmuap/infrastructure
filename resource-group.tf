resource "azurerm_resource_group" "azure_resource_group" {
  #ts:skip=AC_AZURE_0389 in development we allow deletion of resource groups
  name     = var.PROJECT_NAME
  location = var.LOCATION
  tags = {
    Username = var.OWNER_EMAIL
    Name     = var.NAME
  }
  lifecycle {
    ignore_changes = [
      tags["CreatedOnDate"],
    ]
  }
}
