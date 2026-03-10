#Key Vault
data "azurerm_key_vault" "kv" {
  name                = var.key_vault_name
  resource_group_name = var.key_vault_resource_group
}

#admin password secret from Kv
data "azurerm_key_vault_secret" "admin_password" {
  name         = var.admin_password_keyvault
  key_vault_id = data.azurerm_key_vault.kv.id
}

data "azurerm_shared_image_version" "image" {
  name                = var.image_version
  image_name          = var.image_name
  gallery_name        = var.gallery_name
  resource_group_name = var.gallery_rg
}

#subnet
data "azurerm_subnet" "subnet" {
  name                 = var.subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = var.resource_group_name
}

#Host Pool
data "azurerm_virtual_desktop_host_pool" "existing" {
  name                = var.hostpool_name
  resource_group_name = var.resource_group_name
}

# Create network interface
resource "azurerm_network_interface" "nic" {
  count               = var.vm_count
  name                = "${var.vm_name}-${count.index}-nic"
  location            = var.location
  resource_group_name = var.resource_group_name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

# VM creation
resource "azurerm_windows_virtual_machine" "vm" {
  count                 = var.vm_count
  name                  = "${var.vm_name}-${count.index}"
  resource_group_name   = var.resource_group_name
  location              = var.location
  size                  = var.vm_size
  admin_username        = var.admin_username
  admin_password        = data.azurerm_key_vault_secret.admin_password.value
  network_interface_ids = [azurerm_network_interface.nic[count.index].id]
  provision_vm_agent    = true

  identity {
    type = "SystemAssigned"
  }

  source_image_id = data.azurerm_shared_image_version.image.id

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    name                 = "${var.vm_name}-${count.index}-osdisk"
  }

  tags = {
    AVDAZServices      = "AVD Components"
    AVDInfra           = "Virtual Machine"
    excludeFromScaling = "excludeFromScaling"
  }
}

# -------------------------------------------------------
# CHANGE 1: AAD Login Extension
#   - type_handler_version: "1.0" -> "2.0"
#   - Added auto_upgrade_minor_version = true
#   - Added settings block with mdmId for Intune auto-enrollment
#     mdmId "0000000a-0000-0000-c000-000000000000" is Microsoft Intune's
#     fixed, well-known App ID (same across all tenants).
#     Without this, AAD join happens but Intune enrollment is skipped.
# -------------------------------------------------------
resource "azurerm_virtual_machine_extension" "aad_login" {
  count                      = var.vm_count
  name                       = "AADLoginForWindows-${count.index}"
  virtual_machine_id         = azurerm_windows_virtual_machine.vm[count.index].id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADLoginForWindows"
  type_handler_version       = "2.0"
  auto_upgrade_minor_version = true

  settings = jsonencode({
    mdmId = "0000000a-0000-0000-c000-000000000000"
  })
}

# -------------------------------------------------------
# CHANGE 2: Registration token lifecycle
#   - Removed ignore_changes on expiration_date
#   - With ignore_changes, token would go stale on re-runs
#     (e.g. your monthly AVD recreation cycles) and new VMs
#     would fail to register to the host pool.
# -------------------------------------------------------
resource "azurerm_virtual_desktop_host_pool_registration_info" "registration" {
  hostpool_id     = data.azurerm_virtual_desktop_host_pool.existing.id
  expiration_date = timeadd(timestamp(), "24h")
}

#Outputs
output "session_host_names" {
  value = [for vm in azurerm_windows_virtual_machine.vm : vm.name]
}

output "registration_token" {
  value     = azurerm_virtual_desktop_host_pool_registration_info.registration.token
  sensitive = true
}

# -------------------------------------------------------
# CHANGE 3: DSC modulesUrl
#   - Replaced hardcoded versioned URL with the versionless
#     pointer maintained by Microsoft. The old versioned URL
#     (Configuration_1.0.02714.342.zip) can be deprecated
#     anytime, breaking new deployments silently.
# -------------------------------------------------------
resource "azurerm_virtual_machine_extension" "avd_registration" {
  count                      = var.vm_count
  name                       = "AVDRegistration-${count.index}"
  virtual_machine_id         = azurerm_windows_virtual_machine.vm[count.index].id
  publisher                  = "Microsoft.Powershell"
  type                       = "DSC"
  type_handler_version       = "2.83"
  auto_upgrade_minor_version = true

  settings = jsonencode({
    modulesUrl            = "https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration.zip",
    configurationFunction = "Configuration.ps1\\AddSessionHost",
    properties = {
      hostPoolName = data.azurerm_virtual_desktop_host_pool.existing.name,
      aadJoin      = true
    }
  })

  protected_settings = jsonencode({
    properties = {
      registrationInfoToken = azurerm_virtual_desktop_host_pool_registration_info.registration.token
    }
  })

  depends_on = [
    azurerm_virtual_machine_extension.aad_login,
    azurerm_virtual_desktop_host_pool_registration_info.registration
  ]
}

# -------------------------------------------------------
# CHANGE 4: Intune enrollment CustomScript extension - REMOVED
#   - The DeviceEnroller.exe busy-wait loop was a workaround
#     for the missing mdmId in the AAD extension (Change 1).
#   - Now that mdmId is set, enrollment is automatic and this
#     extension is no longer needed.
#   - Also had risks: silent timeout if AAD join took too long,
#     no retry limit on the while loop.
# -------------------------------------------------------
# (intune_enrollment extension block deleted)
