terraform {
  required_version = ">= 1.8"

  required_providers {
    infisical = {
      source  = "Infisical/infisical"
      version = "~> 0.16"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
  }
}
