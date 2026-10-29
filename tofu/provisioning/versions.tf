terraform {
  required_version = ">= 1.8"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.118"
    }
    matchbox = {
      source  = "poseidon/matchbox"
      version = "~> 0.5"
    }
  }
}
