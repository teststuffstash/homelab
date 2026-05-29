terraform {
  required_version = ">= 1.8"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.107"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.11"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
  }
}
