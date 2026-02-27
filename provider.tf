terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
  backend "azurerm" {
    resource_group_name   = ""
    storage_account_name  = ""
    container_name        = ""
    key                   = "avd-fbmtest.tfstate"
  }
}

provider "azurerm" {
  features {}
  }
