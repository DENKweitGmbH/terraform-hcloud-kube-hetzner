# This file handles the automatic provisioning of custom agent nodes via SSH

resource "null_resource" "provision_custom_agent" {
  for_each = { for idx, agent in var.custom_agent_nodepools : agent.name => agent }

  triggers = {
    config_content         = local.k3s_custom_agent_config_map[each.key]
    install_script_content = local.k3s_custom_agent_install_script_map[each.key]
    api_endpoint           = local.control_plane_external_api_endpoint
    k3s_token              = sensitive(local.k3s_token)
    # OS-specific trigger for prerequisites
    os_type = each.value.os_type
    # Trigger for destroy-time provisioner name reference
    agent_name = each.key
    # Triggers for connection block
    conn_external_ip                    = each.value.external_ip
    conn_ssh_user                       = each.value.ssh_user
    conn_ssh_port                       = coalesce(each.value.ssh_port, 22)
    conn_ssh_private_key_path_content   = each.value.ssh_private_key_path != null ? file(each.value.ssh_private_key_path) : null
    conn_var_ssh_private_key            = var.ssh_private_key
    conn_ssh_use_agent                  = each.value.ssh_use_agent
    conn_ssh_agent_identity_is_not_null = (local.ssh_agent_identity != null)
  }

  connection {
    type        = "ssh"
    host        = self.triggers.conn_external_ip
    user        = self.triggers.conn_ssh_user
    port        = self.triggers.conn_ssh_port
    private_key = self.triggers.conn_ssh_private_key_path_content != null ? self.triggers.conn_ssh_private_key_path_content : (self.triggers.conn_var_ssh_private_key != "" && !coalesce(self.triggers.conn_ssh_use_agent, self.triggers.conn_ssh_agent_identity_is_not_null) ? self.triggers.conn_var_ssh_private_key : null)
    agent       = coalesce(self.triggers.conn_ssh_use_agent, self.triggers.conn_ssh_agent_identity_is_not_null)
    timeout     = "5m"
  }

  # Check prerequisites like WireGuard tools - but don't install automatically
  provisioner "remote-exec" {
    inline = [
      "set -ex",
      "echo \"Checking prerequisites on ${self.triggers.agent_name}...\"",
      "if [ \"${self.triggers.os_type}\" = \"linux_debian_ubuntu\" ]; then",
      "  if ! dpkg -s wireguard-tools > /dev/null 2>&1; then",
      "    echo \"WARNING: wireguard-tools not installed on ${self.triggers.agent_name}. Please install it manually with: sudo apt-get update -y && sudo apt-get install -y wireguard-tools\"",
      "  else",
      "    echo \"wireguard-tools already installed on ${self.triggers.agent_name}.\"",
      "  fi",
      "elif [ \"${self.triggers.os_type}\" = \"linux_rhel_centos\" ]; then",
      "  if ! rpm -q wireguard-tools > /dev/null 2>&1; then",
      "    echo \"WARNING: wireguard-tools not installed on ${self.triggers.agent_name}. Please install it manually with: sudo yum install -y epel-release && sudo yum install -y wireguard-tools\"",
      "  else",
      "    echo \"wireguard-tools already installed on ${self.triggers.agent_name}.\"",
      "  fi",
      "else",
      "  echo \"WARNING: Unknown OS type: ${self.triggers.os_type} on ${self.triggers.agent_name}. Please ensure wireguard-tools is installed manually.\"",
      "fi"
    ]
  }

  # Create K3s directory
  provisioner "remote-exec" {
    inline = ["echo 'Creating /etc/rancher/k3s on ${self.triggers.agent_name}...'", "sudo mkdir -p /etc/rancher/k3s"]
  }

  # Upload config.yaml
  provisioner "file" {
    content     = self.triggers.config_content
    destination = "/tmp/k3s_config_for_${self.triggers.agent_name}.yaml"
  }

  # Move config and set permissions - checks for changes before overwriting
  provisioner "remote-exec" {
    inline = [
      "CONFIG_PATH=\"/etc/rancher/k3s/config.yaml\"",
      "TEMP_CONFIG_PATH=\"/tmp/k3s_config_for_${self.triggers.agent_name}.yaml\"",
      "echo \"Checking K3s config on ${self.triggers.agent_name}...\"",
      "if [ ! -f \"$CONFIG_PATH\" ] || ! sudo cmp -s \"$TEMP_CONFIG_PATH\" \"$CONFIG_PATH\"; then",
      "  echo \"Updating K3s config on ${self.triggers.agent_name}...\"",
      "  sudo mv \"$TEMP_CONFIG_PATH\" \"$CONFIG_PATH\"",
      "  sudo chmod 0600 \"$CONFIG_PATH\"",
      "else",
      "  echo \"K3s config on ${self.triggers.agent_name} is already up-to-date. Cleaning up temp file.\"",
      "  sudo rm \"$TEMP_CONFIG_PATH\"",
      "fi"
    ]
  }

  # Run K3s install script
  provisioner "remote-exec" {
    inline = ["echo 'Running K3s agent install script on ${self.triggers.agent_name}...'", self.triggers.install_script_content]
  }

  # Enable, start, and verify K3s agent service
  provisioner "remote-exec" {
    inline = [
      "echo \"Ensuring k3s-agent service is active on ${self.triggers.agent_name}...\"",
      "sudo systemctl enable k3s-agent",
      "if sudo systemctl is-active --quiet k3s-agent; then",
      "  echo \"k3s-agent on ${self.triggers.agent_name} is active. Restarting to apply any changes.\"",
      "  sudo systemctl restart k3s-agent",
      "else",
      "  echo \"k3s-agent on ${self.triggers.agent_name} is not active. Starting it now.\"",
      "  sudo systemctl start k3s-agent",
      "fi",
      "sleep 5 # Give service time to settle/fail",
      "if ! sudo systemctl is-active --quiet k3s-agent; then",
      "  echo \"ERROR: k3s-agent on ${self.triggers.agent_name} failed to start after provisioning attempt. Check logs on the node: journalctl -u k3s-agent -n 200\"",
      "  exit 1 # Fail the resource if K3s agent doesn't start",
      "else",
      "  echo \"k3s-agent on ${self.triggers.agent_name} is confirmed active.\"",
      "fi"
    ]
  }

  depends_on = [
    null_resource.control_planes # Ensure CPs are up and LB IP is available if used for endpoint
  ]

  # Destroy-time provisioner to uninstall K3s from the custom agent
  # MOVED to null_resource.deprovision_custom_agent_os
}

# This resource handles the OS-level deprovisioning of the custom agent (K3s uninstall)
# resource "null_resource" "deprovision_custom_agent_os" {
#   for_each = { for idx, agent in var.custom_agent_nodepools : agent.name => agent }
# 
#   triggers = {
#     # Triggers to ensure connection details are current for the destroy-time provisioner
#     agent_name                          = each.key
#     conn_external_ip                    = each.value.external_ip
#     conn_ssh_user                       = each.value.ssh_user
#     conn_ssh_port                       = coalesce(each.value.ssh_port, 22)
#     conn_ssh_private_key_path_content   = each.value.ssh_private_key_path != null ? file(each.value.ssh_private_key_path) : null
#     conn_var_ssh_private_key            = var.ssh_private_key
#     conn_ssh_use_agent                  = each.value.ssh_use_agent
#     conn_ssh_agent_identity_is_not_null = (local.ssh_agent_identity != null)
#   }
# 
#   provisioner "remote-exec" {
#     when = destroy
#     connection {
#       type        = "ssh"
#       host        = self.triggers.conn_external_ip
#       user        = self.triggers.conn_ssh_user
#       port        = self.triggers.conn_ssh_port
#       private_key = self.triggers.conn_ssh_private_key_path_content != null ? self.triggers.conn_ssh_private_key_path_content : (self.triggers.conn_var_ssh_private_key != "" && !coalesce(self.triggers.conn_ssh_use_agent, self.triggers.conn_ssh_agent_identity_is_not_null) ? self.triggers.conn_var_ssh_private_key : null)
#       agent       = coalesce(self.triggers.conn_ssh_use_agent, self.triggers.conn_ssh_agent_identity_is_not_null)
#       timeout     = "5m"
#     }
#     inline = [
#       "echo \"Stopping k3s-agent on ${self.triggers.agent_name}...\"",
#       "sudo systemctl stop k3s-agent || true",
#       "sudo systemctl disable k3s-agent || true",
#       "echo \"Uninstalling K3s agent on ${self.triggers.agent_name}...\"",
#       "if [ -f /usr/local/bin/k3s-agent-uninstall.sh ]; then",
#       "  sudo /usr/local/bin/k3s-agent-uninstall.sh",
#       "elif [ -f /usr/local/bin/k3s-uninstall.sh ]; then",
#       "  sudo /usr/local/bin/k3s-uninstall.sh",
#       "else",
#       "  echo \"WARNING: K3s uninstall script not found on ${self.triggers.agent_name}. Manual cleanup may be required.\"",
#       "fi",
#       "echo \"Cleaning up K3s directories on ${self.triggers.agent_name}...\"",
#       "sudo rm -rf /etc/rancher/k3s /var/lib/rancher/k3s",
#       "echo \"K3s agent deprovisioning from node ${self.triggers.agent_name} complete.\""
#     ]
#   }
# }
# 
# # This resource handles deleting the custom agent node from the Kubernetes cluster
# # after it has been deprovisioned from the machine itself.
# resource "null_resource" "delete_custom_agent_node_from_k8s" {
#   for_each = { for agent in var.custom_agent_nodepools : agent.name => agent }
# 
#   triggers = {
#     create_kubeconfig   = var.create_kubeconfig
#     kubeconfig_filename = var.create_kubeconfig && length(local_sensitive_file.kubeconfig) > 0 ? local_sensitive_file.kubeconfig[0].filename : null
#     node_name           = each.value.name # Make node_name explicitly part of triggers
#   }
# 
#   provisioner "local-exec" {
#     when = destroy
#     command = (
#       self.triggers.create_kubeconfig && self.triggers.kubeconfig_filename != null ?
#       "kubectl --kubeconfig ${self.triggers.kubeconfig_filename} delete node ${self.triggers.node_name} --ignore-not-found=true" :
#       "echo \"Skipping kubectl delete node for ${self.triggers.node_name}: var.create_kubeconfig is false or kubeconfig file not found.\""
#     )
#     interpreter = ["bash", "-c"]
#   }
# 
#   depends_on = [
#     null_resource.deprovision_custom_agent_os
#   ]
# }
