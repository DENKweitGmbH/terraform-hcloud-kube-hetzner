# New Requirement: Automatic Provisioning of Custom Agent Nodes

The core requirement for the "Custom Agent Nodes (Multicloud)" feature has been updated. Previously, the plan was for Terraform to output configuration files and installation scripts, which the user would then manually apply to their pre-existing external machines.

**The new requirement is for Terraform to fully and automatically provision these custom agent nodes.**

This means Terraform, upon `apply`, will:

1.  Connect to each defined custom agent machine via SSH.
2.  Execute the necessary commands **idempotently** to:
    *   Install prerequisites (e.g., `wireguard-tools`), potentially based on a user-provided OS hint. The script should check if prerequisites are already installed.
    *   Create the K3s agent configuration directory (`/etc/rancher/k3s`).
    *   Place the generated `config.yaml` onto the custom agent machine. **Crucially, Terraform should verify if an existing `config.yaml` is identical to the new one before overwriting to prevent unnecessary service restarts and to ensure changes are actually applied.**
    *   Run the K3s agent installation script (`curl ... | INSTALL_K3S_EXEC='agent' sh -`). The K3s installer itself is generally idempotent.
    *   Enable and start the `k3s-agent` service. **The provisioning script must check the status of the `k3s-agent` service after attempting to start/restart it. If the service fails to become active, the Terraform resource for that agent should ideally indicate an error.**

**Key Aspects for Robustness:**

*   **Stateful Triggers:** The Terraform `null_resource` responsible for provisioning will use a comprehensive `triggers` block. This block will include the content of the `config.yaml`, the install script, API endpoint details, K3s token, and SSH connection parameters. Changes to any of these will cause the provisioning steps to re-run.
*   **Idempotent Scripting:** All `remote-exec` provisioner scripts should be written to be idempotent. For example, checking if a package is already installed before trying to install it, or checking if a file content matches before replacing it.
*   **Service Verification:** After the K3s agent installation and service start/restart, the scripts must verify that the `k3s-agent` service is running and active. If it's not, the provisioning for that node should be considered failed.

**Implications:**

*   Terraform will require SSH access (network path) to the custom agent machines from the host where Terraform is run. The `custom_agent_nodepools` variable will allow specifying per-node SSH settings:
    *   `ssh_user` (required).
    *   `ssh_port` (optional).
    *   `ssh_private_key_path` (optional): For a specific private key for that node.
    *   `ssh_use_agent` (optional): To explicitly control SSH agent use for that node.
    *   `os_type` (optional): To help select the correct package manager for prerequisites.
    *   If per-node SSH settings are not fully specified, the module will fall back to global SSH configurations (`var.ssh_private_key`, `var.ssh_port`, and SSH agent detection via `local.ssh_agent_identity`).
*   The `multicloud_agents_plan.md` has been updated to reflect these changes, primarily by replacing manual provisioning steps with Terraform `null_resource` provisioners that execute commands remotely, incorporating detailed `triggers`, and idempotent, state-aware scripts.
*   The outputs related to custom agents will shift from being primarily for manual execution to being for informational/debugging purposes, and to report the status of the automatic provisioning attempt.
*   The user remains responsible for ensuring the custom agent machine's firewall is configured to allow necessary traffic (e.g., WireGuard UDP port to other nodes, SSH access from the Terraform host). Terraform will not manage firewalls on custom/external machines. 