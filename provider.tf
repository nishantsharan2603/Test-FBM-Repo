terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
  backend "azurerm" {
    resource_group_name   = "fbm-wms-stage-avd"
    storage_account_name  = "avdprodfbmstc01"
    container_name        = "tfstate"
    key                   = "avd-fbmtest.tfstate"
  }
}

provider "azurerm" {
  features {}
  }
