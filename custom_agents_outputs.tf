output "custom_agent_configurations" {
  description = "Provides the k3s agent configuration and installation script for each custom agent node. Apply these on your external machines."
  value = {
    for agent_details in var.custom_agent_nodepools : agent_details.name => {
      config_yaml_content = local.k3s_custom_agent_config_map[agent_details.name]
      install_script      = local.k3s_custom_agent_install_script_map[agent_details.name]
      instructions        = <<-EOT
        To provision custom agent '${agent_details.name}' (IP: ${agent_details.external_ip}):
        1. SSH into your custom machine (e.g., ssh ${coalesce(agent_details.ssh_user, "root")}@${agent_details.external_ip} -p ${coalesce(agent_details.ssh_port, 22)}).
        2. Ensure the WireGuard UDP port ${var.wireguard_udp_port} (default 51820) is open for inbound traffic on this machine's firewall.
        3. If using Calico or Cilium CNI, ensure WireGuard tools (e.g., `wireguard-tools` package) are installed.
        4. Create the k3s configuration directory: sudo mkdir -p /etc/rancher/k3s
        5. Create the configuration file: sudo nano /etc/rancher/k3s/config.yaml
           Paste the following content into the file:
           ---
           ${local.k3s_custom_agent_config_map[agent_details.name]}
           ---
        6. Set correct permissions: sudo chmod 0600 /etc/rancher/k3s/config.yaml
        7. Run the installation script:
           ${local.k3s_custom_agent_install_script_map[agent_details.name]}
        8. Start the k3s agent: sudo systemctl enable --now k3s-agent
        9. Verify the node joins the cluster: On a control plane or machine with kubectl, run 'kubectl get nodes'.
      EOT
    }
  }
  sensitive = true # k3s_token
  depends_on = [
    null_resource.control_planes # Ensure CPs are up and LB IP is available if used for endpoint
  ]
}
