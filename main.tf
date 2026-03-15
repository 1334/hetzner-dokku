terraform {
  required_version = ">= 1.5"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

resource "terraform_data" "workspace_check" {
  lifecycle {
    precondition {
      condition     = terraform.workspace == var.workspace_name
      error_message = "Workspace '${terraform.workspace}' does not match workspace_name '${var.workspace_name}'. Switch with: terraform workspace select ${var.workspace_name}"
    }
  }
}

# SSH Key
resource "hcloud_ssh_key" "deploy" {
  name       = "${var.server_name}-key"
  public_key = var.ssh_public_key
}

# Server
resource "hcloud_server" "dokku" {
  name        = var.server_name
  image       = "ubuntu-24.04"
  server_type = var.server_type
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.deploy.id]

  user_data = templatefile("${path.module}/cloud-init.yaml", {
    ssh_public_key = var.ssh_public_key
    email_domain   = var.email_domain
    ntfy_topic     = var.ntfy_topic
    ntfy_schedule  = var.ntfy_schedule
  })

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  lifecycle {
    ignore_changes = [user_data]
  }
}

# Run setup.sh when enable_oauth changes or on first provision
resource "null_resource" "setup" {
  triggers = {
    enable_oauth = var.enable_oauth
    server_ip    = hcloud_server.dokku.ipv4_address
  }

  provisioner "local-exec" {
    command = "${path.module}/setup.sh"
    environment = {
      TF_SERVER_IP    = hcloud_server.dokku.ipv4_address
      TF_ENABLE_OAUTH = var.enable_oauth
      TF_EMAIL_DOMAIN = var.email_domain
    }
  }

  depends_on = [hcloud_server.dokku]
}

# Run setup-ntfy.sh when notification config changes
resource "null_resource" "ntfy" {
  triggers = {
    ntfy_topic    = var.ntfy_topic
    ntfy_schedule = var.ntfy_schedule
    server_ip     = hcloud_server.dokku.ipv4_address
  }

  provisioner "local-exec" {
    command = "${path.module}/setup-ntfy.sh"
    environment = {
      TF_SERVER_IP     = hcloud_server.dokku.ipv4_address
      TF_NTFY_TOPIC    = var.ntfy_topic
      TF_NTFY_SCHEDULE = var.ntfy_schedule
    }
  }

  depends_on = [hcloud_server.dokku]
}
