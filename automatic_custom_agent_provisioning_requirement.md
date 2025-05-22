# New Requirement: Automatic Provisioning of Custom Agent Nodes

The core requirement for the "Custom Agent Nodes (Multicloud)" feature has been updated. Previously, the plan was for Terraform to output configuration files and installation scripts, which the user would then manually apply to their pre-existing external machines.

**The new requirement is for Terraform to fully and automatically provision these custom agent nodes.**

This means Terraform, upon `apply`, will:

1.  Connect to each defined custom agent machine via SSH.
2.  Execute the necessary commands to:
    *   Install prerequisites (e.g., `wireguard-tools`), potentially based on a user-provided OS hint.
    *   Create the K3s agent configuration directory (`/etc/rancher/k3s`).
    *   Place the generated `config.yaml` (containing the server URL, K3s token, node-external-ip, labels, taints, etc.) onto the custom agent machine.
    *   Run the K3s agent installation script (`curl ... | INSTALL_K3S_EXEC='agent' sh -`).
    *   Enable and start the `k3s-agent` service.

**Implications:**

*   Terraform will require SSH access (network path) to the custom agent machines from the host where Terraform is run. The `custom_agent_nodepools` variable will allow specifying per-node SSH settings:
    *   `ssh_user` (required).
    *   `ssh_port` (optional).
    *   `ssh_private_key_path` (optional): For a specific private key for that node.
    *   `ssh_use_agent` (optional): To explicitly control SSH agent use for that node.
    *   If per-node SSH settings are not fully specified, the module will fall back to global SSH configurations (`var.ssh_private_key`, `var.ssh_port`, and SSH agent detection via `local.ssh_agent_identity`).
*   The `multicloud_agents_plan.md` has been updated to reflect these changes, primarily by replacing manual provisioning steps with Terraform `null_resource` provisioners that execute commands remotely.
*   The outputs related to custom agents will shift from being primarily for manual execution to being for informational/debugging purposes.
*   The user remains responsible for ensuring the custom agent machine's firewall is configured to allow necessary traffic (e.g., WireGuard UDP port to other nodes, SSH access from the Terraform host). 