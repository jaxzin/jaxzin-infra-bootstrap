terraform {
  required_version = ">= 1.10"

  required_providers {
    unifi = {
      source  = "ubiquiti-community/unifi"
      version = ">= 0.41, < 1.0"
    }
  }
}
