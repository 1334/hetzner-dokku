output "server_ip" {
  value = hcloud_server.dokku.ipv4_address
}

output "server_ipv6" {
  value = hcloud_server.dokku.ipv6_address
}

output "ssh_command" {
  value = "ssh deploy@${hcloud_server.dokku.ipv4_address}"
}

output "enable_oauth" {
  value = var.enable_oauth
}

output "google_client_id" {
  value     = var.google_client_id
  sensitive = true
}

output "google_client_secret" {
  value     = var.google_client_secret
  sensitive = true
}

output "email_domain" {
  value = var.email_domain
}
