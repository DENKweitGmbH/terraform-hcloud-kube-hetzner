output "custom_agent_provisioning_status" {
  description = "Status of automatic provisioning attempts for custom agent nodes. Check K3s agent logs on custom nodes for detailed status."
  value = {
    for agent_details in var.custom_agent_nodepools : agent_details.name => {
      external_ip                   = agent_details.external_ip
      provisioning_result           = "Terraform attempted automatic provisioning. Verify node status with 'kubectl get nodes' and check agent logs on the custom machine if issues persist."
      config_yaml_content_for_debug = sensitive(local.k3s_custom_agent_config_map[agent_details.name])         # For debugging
      install_script_for_debug      = sensitive(local.k3s_custom_agent_install_script_map[agent_details.name]) # For debugging
    }
  }
  sensitive = true
  depends_on = [
    null_resource.provision_custom_agent # Ensure provision attempts are complete
  ]
}
