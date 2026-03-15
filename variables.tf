variable "hcloud_token" {
  description = "Hetzner Cloud API token"
  sensitive   = true
}

variable "ssh_public_key" {
  description = "SSH public key content"
}

variable "server_name" {
  default = "dokku-prod"
}

variable "server_type" {
  default = "cx23" # 2 vCPU, 4GB RAM
}

variable "location" {
  default = "hel1" # Helsinki
}

variable "enable_oauth" {
  description = "Enable Google SSO via oauth2-proxy for all apps"
  type        = bool
  default     = true
}

variable "google_client_id" {
  description = "Google OAuth2 client ID (required if enable_oauth = true)"
  sensitive   = true
  default     = ""
}

variable "google_client_secret" {
  description = "Google OAuth2 client secret (required if enable_oauth = true)"
  sensitive   = true
  default     = ""
}

variable "email_domain" {
  description = "Allowed email domain for SSO"
  default     = "example.com"
}
