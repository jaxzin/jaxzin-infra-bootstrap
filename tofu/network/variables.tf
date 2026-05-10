variable "unifi_api_url" {
  description = "UniFi controller URL, e.g. https://<controller-host>"
  type        = string
}

variable "unifi_username" {
  description = "Local UniFi admin username for OpenTofu (dedicated user, not the operator's account)"
  type        = string
}

variable "unifi_password" {
  description = "Password for the dedicated OpenTofu UniFi user"
  type        = string
  sensitive   = true
}

variable "unifi_site" {
  description = "UniFi site identifier (typically 'default')"
  type        = string
  default     = "default"
}

variable "unifi_insecure" {
  description = "Skip TLS verification on the controller URL (rare; only for self-signed dev controllers)"
  type        = bool
  default     = false
}

variable "unifi_static_dns" {
  description = "List of static DNS records to manage on the UniFi controller."
  type = list(object({
    name  = string
    value = string
    type  = string
  }))
  default = []
  validation {
    condition     = alltrue([for r in var.unifi_static_dns : contains(["A", "AAAA", "CNAME", "TXT"], r.type)])
    error_message = "Each unifi_static_dns record's type must be A, AAAA, CNAME, or TXT."
  }
}
