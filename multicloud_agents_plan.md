Refactored Plan to Implement "Custom Agent Nodes" Feature (v2 - Automatic Provisioning)

Core Principle: The presence of a non-empty `custom_agent_nodepools` list in the user's `kube.tf` will implicitly activate the "multicloud agents" feature, enforcing WireGuard for CNI communication. **Terraform will automatically provision these custom agent nodes via SSH, but users must install WireGuard tools manually on their custom nodes before provisioning.**

I. Introduce New Terraform Variables (in `variables.tf`)

1.  `custom_agent_nodepools`:
    *   Type: `list(object({ ... }))`
    *   Default: `[]`
    *   Description: "A list of objects defining pre-existing custom agent nodes to be **automatically provisioned and integrated** into the cluster. Defining this list automatically enables multicloud agent mode."
    *   Object attributes:
        *   `name`: (string, required) A unique name for the custom agent (e.g., "my-external-server").
        *   `external_ip`: (string, required) The public IP address of the custom agent machine.
        *   `ssh_user`: (string, required, e.g., "ubuntu", "root") The SSH user for Terraform to connect to the custom machine for provisioning.
        *   `ssh_port`: (number, optional, default: 22) The SSH port for Terraform to connect to the custom machine.
        *   `ssh_private_key_path`: (string, optional, default: null) Path to an SSH private key specifically for this custom agent. If set, this key will be used. Takes precedence over global SSH settings for this node.
        *   `ssh_use_agent`: (bool, optional, default: null) Explicitly enable/disable SSH agent for this custom node. If null, behavior depends on `ssh_private_key_path` and global `var.ssh_private_key` / `local.ssh_agent_identity`.
        *   `labels`: (list(string), optional) K3s node labels.
        *   `taints`: (list(string), optional) K3s node taints.
        *   `os_type`: (string, optional, default: "linux_debian_ubuntu") Hint for OS type to determine how to check for WireGuard tools installation (e.g., "linux_debian_ubuntu", "linux_rhel_centos"). **Note: Terraform will NOT install wireguard-tools - users must install it manually before provisioning.**

2.  `wireguard_udp_port`:
    *   Type: `number`
    *   Default: `51820`
    *   Description: "The UDP port for WireGuard tunnels used by Flannel, Calico, or Cilium. This port is automatically opened on Hetzner firewalls when `custom_agent_nodepools` is defined or `enable_wireguard` is true. Users must ensure this port is open on their custom agents' firewalls (Terraform will not manage the custom agent's firewall)."

II. Modify `locals.tf`

1.  `enable_multicloud_agents` (New Local):
    *   `local.enable_multicloud_agents = length(var.custom_agent_nodepools) > 0`

2.  `force_wireguard_for_cni` (New Local):
    *   `local.force_wireguard_for_cni = var.enable_wireguard || local.enable_multicloud_agents`

3.  `control_plane_external_api_endpoint` (Revised Local):
    *   Determines the public-facing API endpoint for agents when `local.enable_multicloud_agents` is true.
    *   Logic:
        ```terraform
        local.control_plane_external_api_endpoint = local.enable_multicloud_agents ? (
          var.kubeconfig_server_address != "" ? var.kubeconfig_server_address : (
            var.use_control_plane_lb ?
            hcloud_load_balancer.control_plane[0].ipv4 : 
            module.control_planes[keys(module.control_planes)[0]].ipv4_address
          )
        ) : null
        ```

4.  K3s Configuration for Control Planes (CPs) and Hetzner Agents (HAs):
    *   If `local.enable_multicloud_agents` is true:
        *   CP K3s args/config: Add `node-external-ip = <CP_PUBLIC_IP>`.
        *   HA K3s args/config: Add `node-external-ip = <HA_PUBLIC_IP>`.
        *   HA K3s config: Set `server = "https://${local.control_plane_external_api_endpoint}:6443"`.

5.  CNI Specific Logic:

    *   **Flannel (`cni_k3s_settings`)**:
        ```terraform
        "flannel" = {
          disable-network-policy = var.disable_network_policy # Or true if multicloud to simplify?
          flannel-backend        = local.force_wireguard_for_cni ? "wireguard-native" : "vxlan"
        }
        ```
        *   If `local.enable_multicloud_agents` is true, CP K3s args/config: Add `flannel-external-ip = true`.

    *   **Calico (`calico_values` or direct kustomize patch for `calico-node` DaemonSet)**:
        *   The existing logic that sets `FELIX_WIREGUARDENABLED` to `true` based on `var.enable_wireguard` will be extended to trigger if `local.force_wireguard_for_cni` is true.
        ```terraform
        # In calico.yaml patch template or similar logic
        - name: FELIX_WIREGUARDENABLED
          value: "${local.force_wireguard_for_cni}"
        ```

    *   **Cilium (`cilium_values`)**:
        ```terraform
        # ... existing cilium_values ...
        %{if local.force_wireguard_for_cni || var.enable_wireguard} # Ensure encryption if multicloud or explicitly enabled
        encryption:
          enabled: true
          type: wireguard
        %{endif~}

        routingMode: "${local.enable_multicloud_agents ? "tunnel" : var.cilium_routing_mode}" # Force tunnel for multicloud
        # If tunnel mode is forced, ensure a tunnelType is set, e.g., tunnelType: vxlan or geneve
        %{if local.enable_multicloud_agents && var.cilium_routing_mode != "tunnel"}
        tunnelType: "vxlan" # Or "geneve", provide a sensible default
        %{endif~}
        # ... rest of cilium_values ...
        ```
        *   Document that `routingMode` is overridden to "tunnel" and WireGuard encryption is enabled if `custom_agent_nodepools` is used with Cilium, irrespective of `var.cilium_routing_mode` or `var.enable_wireguard` being false.

6.  `k3s_custom_agent_config_map` (Generates `config.yaml` for each custom agent):
    *   Iterates `var.custom_agent_nodepools`.
    *   Content for each custom agent:
        ```yaml
        server: "https://${local.control_plane_external_api_endpoint}:6443"
        token: "${local.k3s_token}"
        node-external-ip: "${each.value.external_ip}"
        # CNI Specific Part
        ${ var.cni_plugin == "flannel" ? "flannel-backend: "wireguard-native"" : "flannel-backend: "none"" }
        # User-defined labels and taints
        node-label:
        %{for label in each.value.labels~}
          - "${label}"
        %{endfor~}
        node-taint:
        %{for taint in each.value.taints~}
          - "${taint}"
        %{endfor~}
        ```

7.  `k3s_custom_agent_install_script_map`:
    *   Iterates `var.custom_agent_nodepools`.
    *   Generates the `curl ... | INSTALL_K3S_EXEC='agent' sh -` installation command. The `config.yaml` handles the agent arguments.

III. Modify `control_planes.tf`

*   The `k3s_server_config` will incorporate `node-external-ip` and `flannel-external-ip` if applicable when `local.enable_multicloud_agents` is true.
*   The `tls-san` list for the k3s server must include `local.control_plane_external_api_endpoint` if it's set. Existing logic for LB IPs and CP IPs should mostly cover this, but verify. If `var.kubeconfig_server_address` is used as the endpoint, it's already handled by user convention if they want it in the cert via `var.additional_tls_sans`.

IV. Modify `agents.tf`

*   The `k3s_agent_config` for Hetzner agents will incorporate `node-external-ip` and the correct `server` URL when `local.enable_multicloud_agents` is true.

V. Create `custom_agent_provisioning.tf` (New File or integrated into existing structure, e.g., `agents.tf` or a new module)

*   This file will contain `null_resource` definitions to provision each custom agent.
*   For each `agent` in `var.custom_agent_nodepools` (iterating with `for_each = { for idx, agent in var.custom_agent_nodepools : agent.name => agent }` to use `agent.name` as key):
    *   A `null_resource` named `provision_custom_agent_${each.key}`.
    *   `triggers` block (to ensure re-provisioning if these values change):
        ```terraform
        triggers = {
          config_content         = local.k3s_custom_agent_config_map[each.key]
          install_script_content = local.k3s_custom_agent_install_script_map[each.key]
          api_endpoint           = local.control_plane_external_api_endpoint
          k3s_token              = sensitive(local.k3s_token)
          # Connection-specific triggers
          external_ip            = each.value.external_ip
          ssh_user               = each.value.ssh_user
          ssh_port               = coalesce(each.value.ssh_port, 22)
          ssh_private_key_path   = each.value.ssh_private_key_path # Re-eval if key path changes
          ssh_use_agent          = each.value.ssh_use_agent
          # OS-specific trigger for prerequisites
          os_type                = each.value.os_type
        }
        ```
    *   `connection` block:
        *   `type`: "ssh"
        *   `host`: `each.value.external_ip`
        *   `user`: `each.value.ssh_user`
        *   `port`: `coalesce(each.value.ssh_port, 22)`
        *   `private_key`: `each.value.ssh_private_key_path != null ? file(each.value.ssh_private_key_path) : (var.ssh_private_key != "" && !coalesce(each.value.ssh_use_agent, local.ssh_agent_identity != null) ? var.ssh_private_key : null)`
        *   `agent_identity`: `coalesce(each.value.ssh_use_agent, local.ssh_agent_identity != null) ? (each.value.ssh_private_key_path != null ? file(each.value.ssh_private_key_path) : local.ssh_agent_identity) : null` (Note: `local.ssh_agent_identity` uses `var.ssh_public_key` as identity if `var.ssh_private_key` is null).
        *   `timeout`: e.g., "5m"
    *   `provisioner "remote-exec"` (Check if WireGuard tools are installed - No automatic installation):
        *   `inline`: Script that only checks for WireGuard tools installation.
          ```bash
          # Only check if wireguard-tools is installed - the user must install it manually
          if [ "${each.value.os_type}" = "linux_debian_ubuntu" ]; then
            if ! dpkg -s wireguard-tools > /dev/null 2>&1; then
              echo "WARNING: wireguard-tools is NOT installed on ${each.value.name}."
              echo "Please install it manually with: sudo apt-get update -y && sudo apt-get install -y wireguard-tools"
              echo "CNI communication will not work without wireguard-tools installed."
            else
              echo "Wireguard-tools is installed on ${each.value.name}."
            fi
          elif [ "${each.value.os_type}" = "linux_rhel_centos" ]; then
            if ! rpm -q wireguard-tools > /dev/null 2>&1; then
              echo "WARNING: wireguard-tools is NOT installed on ${each.value.name}."
              echo "Please install it manually with: sudo yum install -y epel-release && sudo yum install -y wireguard-tools"
              echo "CNI communication will not work without wireguard-tools installed."
            else
              echo "Wireguard-tools is installed on ${each.value.name}."
            fi
          else
            echo "Unable to check wireguard-tools installation for unknown OS type: ${each.value.os_type} on ${each.value.name}"
            echo "Please ensure wireguard-tools is installed manually on this node."
          fi
          ```
    *   `provisioner "remote-exec"` (Create K3s directory):
        *   `inline`: `["echo 'Creating /etc/rancher/k3s on ${each.value.name}...'", "sudo mkdir -p /etc/rancher/k3s"]`
    *   `provisioner "file"` (Upload `config.yaml`):
        *   `content`: `local.k3s_custom_agent_config_map[each.key]`
        *   `destination`: "/tmp/k3s_config_for_${each.key}.yaml"
    *   `provisioner "remote-exec"` (Move config and set permissions - checks for changes before overwriting):
        *   `inline`:
          ```bash
          CONFIG_PATH="/etc/rancher/k3s/config.yaml"
          TEMP_CONFIG_PATH="/tmp/k3s_config_for_${each.key}.yaml"
          echo "Checking K3s config on ${each.value.name}..."
          if [ ! -f "$CONFIG_PATH" ] || ! sudo cmp -s "$TEMP_CONFIG_PATH" "$CONFIG_PATH"; then
            echo "Updating K3s config on ${each.value.name}..."
            sudo mv "$TEMP_CONFIG_PATH" "$CONFIG_PATH"
            sudo chmod 0600 "$CONFIG_PATH"
          else
            echo "K3s config on ${each.value.name} is already up-to-date. Cleaning up temp file."
            sudo rm "$TEMP_CONFIG_PATH"
          fi
          ```
    *   `provisioner "remote-exec"` (Run K3s install script - K3s installer is generally idempotent):
        *   `inline`: `["echo 'Running K3s agent install script on ${each.value.name}...'", local.k3s_custom_agent_install_script_map[each.key]]`
    *   `provisioner "remote-exec"` (Enable, start, and verify K3s agent service):
        *   `inline`:
          ```bash
          echo "Ensuring k3s-agent service is active on ${each.value.name}..."
          sudo systemctl enable k3s-agent
          if sudo systemctl is-active --quiet k3s-agent; then
            echo "k3s-agent on ${each.value.name} is active. Restarting to apply any changes."
            sudo systemctl restart k3s-agent
          else
            echo "k3s-agent on ${each.value.name} is not active. Starting it now."
            sudo systemctl start k3s-agent
          fi
          sleep 5 # Give service time to settle/fail
          if ! sudo systemctl is-active --quiet k3s-agent; then
            echo "ERROR: k3s-agent on ${each.value.name} failed to start after provisioning attempt. Check logs on the node: journalctl -u k3s-agent -n 200"
            exit 1 # Fail the resource if K3s agent doesn't start
          else
            echo "k3s-agent on ${each.value.name} is confirmed active."
          fi
          ```
    *   `depends_on`: Should include `null_resource.control_planes` from `control_planes.tf` (or a similar signal that control planes are ready and LB IP is available if used for the endpoint).

VI. Modify `custom_agents_outputs.tf`

*   The `custom_agent_configurations` output will be renamed and revised (as per previous plan v2 update).
    ```terraform
    output "custom_agent_provisioning_status" {
      description = "Status of automatic provisioning attempts for custom agent nodes. Check K3s agent logs on custom nodes for detailed status."
      value = {
        for agent_details in var.custom_agent_nodepools : agent_details.name => {
          external_ip         = agent_details.external_ip
          provisioning_result = "Terraform attempted automatic provisioning. Verify node status with 'kubectl get nodes' and check agent logs on the custom machine if issues persist."
          config_yaml_content_for_debug = sensitive(local.k3s_custom_agent_config_map[agent_details.name]) # For debugging
          install_script_for_debug      = sensitive(local.k3s_custom_agent_install_script_map[agent_details.name]) # For debugging
        }
      }
      sensitive = true
    }
    ```

VII. Modify `main.tf` (Firewall Rules in `locals.tf`)

*   In `local.base_firewall_rules`, the rule for WireGuard UDP port is modified:
    ```terraform
    # (existing firewall rules)
    # Add rule for WireGuard if custom agents are used OR var.enable_wireguard is true
    local.force_wireguard_for_cni ? [
      {
        description     = "Allow Inbound WireGuard UDP for k3s CNI"
        direction       = "in"
        protocol        = "udp"
        port            = tostring(var.wireguard_udp_port) # Uses the variable with default 51820
        source_ips      = ["0.0.0.0/0", "::/0"] # Consider if this should be more restrictive
        destination_ips = [] # Applied to all Hetzner nodes
      }
    ] : [],
    # (rest of firewall rules)
    ```

VIII. Update `kube.tf.example`

*   Update `custom_agent_nodepools` example to include `ssh_user` (as required) and demonstrate `ssh_port`, `ssh_private_key_path`, `ssh_use_agent`, `os_type`.
*   Update comments to reflect automatic provisioning by Terraform and the need for SSH access from the Terraform host.
*   **Add a CRITICAL PREREQUISITE section that clearly states users must install wireguard-tools manually on their custom agent machines before running Terraform.**
*   Include examples of how to install wireguard-tools on different operating systems.
*   Emphasize user responsibility for firewall rules on the custom agent machine itself.

IX. Update `README.md`

*   Update section "Custom Agent Nodes (Multicloud)".
*   Explain that provisioning is now automatic via SSH.
*   Detail SSH requirements (key, user, port, network path from Terraform host to custom agents).
*   Explain `ssh_private_key_path`, `ssh_use_agent`, and `os_type` options.
*   **Emphasize that users MUST install WireGuard tools themselves on their custom agent machines before Terraform provisioning.**
*   Provide OS-specific installation instructions for wireguard-tools (Ubuntu/Debian, CentOS/RHEL, etc.).
*   Stress that the user must ensure the custom agent's firewall permits WireGuard UDP traffic.
*   Reference `custom_agent_provisioning_status` output.

X. Conceptual Flow Diagram (No significant change from previous plan v2 update with automatic provisioning)

This refined plan provides more specific guidance on implementing automatic provisioning, drawing from existing patterns in the codebase while accommodating the unique aspects of pre-existing custom nodes.

```mermaid
graph LR
    A[User defines `custom_agent_nodepools` with SSH details in kube.tf] --> B{Terraform Plan/Apply};

    subgraph Terraform Execution
        B --> C1[Modifies CP k3s config: adds --node-external-ip, --flannel-external-ip];
        B --> C2[Modifies Hetzner Agent k3s config: sets server to Public LB IP, adds --node-external-ip];
        B --> C3[**Terraform SSHes to Custom Agents & Provisions K3s Agent**];
        C3 --> C3a[Checks if wireguard-tools is installed (user must install manually)];
        C3 --> C3b[Creates /etc/rancher/k3s/config.yaml];
        C3 --> C3c[Runs K3s install script];
        C3 --> C3d[Starts k3s-agent service];
        B --> C4[Updates Hetzner Firewall: opens WireGuard UDP port];
    end

    C3 --> D[Outputs Custom Agent provisioning status];

    subgraph Kubernetes Cluster
        F[Hetzner Control Planes (Public IPs for k3s, Private for etcd)]
        G[Hetzner Agents (Public IPs for k3s)]
        H[Custom Agents (Public IPs for k3s, **provisioned by Terraform**)]

        F -- "k3s API (via Public LB IP)" --> G;
        F -- "k3s API (via Public LB IP)" --> H;
        G -- "CNI (WireGuard over Public IPs)" --> H;
        G -- "CNI (WireGuard over Public IPs)" --> F;
        H -- "CNI (WireGuard over Public IPs)" --> F;
    end

    style A fill:#lightgrey,stroke:#333
    style B fill:#lightblue,stroke:#333
    style C3 fill:#lightgreen,stroke:#333
```
