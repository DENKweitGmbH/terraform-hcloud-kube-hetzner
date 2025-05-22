Refactored Plan to Implement "Custom Agent Nodes" Feature (v2 - Automatic Provisioning)

Core Principle: The presence of a non-empty `custom_agent_nodepools` list in the user's `kube.tf` will implicitly activate the "multicloud agents" feature, enforcing WireGuard for CNI communication. **Terraform will automatically provision these custom agent nodes via SSH.**

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
        *   `os_type`: (string, optional, default: "linux_debian_ubuntu") Hint for OS type to determine package manager commands for prerequisites (e.g., "linux_debian_ubuntu", "linux_rhel_centos"). Defaults to assuming apt for `wireguard-tools`.

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
    *   `triggers`: Include `local.k3s_custom_agent_config_map[each.key]`, `local.k3s_custom_agent_install_script_map[each.key]`, `local.control_plane_external_api_endpoint`, `local.k3s_token` to re-run provisioning if these change.
    *   `connection` block:
        *   `type`: "ssh"
        *   `host`: `each.value.external_ip`
        *   `user`: `each.value.ssh_user`
        *   `port`: `coalesce(each.value.ssh_port, 22)`
        *   `private_key`: `each.value.ssh_private_key_path != null ? file(each.value.ssh_private_key_path) : (var.ssh_private_key != "" && !coalesce(each.value.ssh_use_agent, local.ssh_agent_identity != null) ? var.ssh_private_key : null)`
        *   `agent_identity`: `coalesce(each.value.ssh_use_agent, local.ssh_agent_identity != null) ? (each.value.ssh_private_key_path != null ? file(each.value.ssh_private_key_path) : local.ssh_agent_identity) : null` (Note: `local.ssh_agent_identity` uses `var.ssh_public_key` as identity if `var.ssh_private_key` is null).
        *   `timeout`: e.g., "5m"
    *   `provisioner "remote-exec"` (Install prerequisites like WireGuard tools):
        *   `inline`: Script based on `each.value.os_type`.
          ```bash
          # Example for Debian/Ubuntu
          if [ "${each.value.os_type}" = "linux_debian_ubuntu" ]; then
            if ! dpkg -s wireguard-tools > /dev/null 2>&1; then
              echo "Installing wireguard-tools..."
              sudo apt-get update -y && sudo apt-get install -y wireguard-tools
            fi
          elif [ "${each.value.os_type}" = "linux_rhel_centos" ]; then
            if ! rpm -q wireguard-tools > /dev/null 2>&1; then
              echo "Installing wireguard-tools..."
              sudo yum install -y epel-release && sudo yum install -y wireguard-tools # Example, might need adjustment
            fi
          else
            echo "Skipping prerequisite installation for unknown OS type: ${each.value.os_type}"
          fi
          ```
    *   `provisioner "remote-exec"` (Create K3s directory):
        *   `inline`: `["sudo mkdir -p /etc/rancher/k3s"]`
    *   `provisioner "file"` (Upload `config.yaml`):
        *   `content`: `local.k3s_custom_agent_config_map[each.key]`
        *   `destination`: "/tmp/config.yaml"
    *   `provisioner "remote-exec"` (Move config and set permissions):
        *   `inline`: `["sudo mv /tmp/config.yaml /etc/rancher/k3s/config.yaml", "sudo chmod 0600 /etc/rancher/k3s/config.yaml"]`
    *   `provisioner "remote-exec"` (Run K3s install script):
        *   `inline`: `[local.k3s_custom_agent_install_script_map[each.key]]`
    *   `provisioner "remote-exec"` (Enable and start K3s agent):
        *   `inline`: `["sudo systemctl enable --now k3s-agent"]`
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
*   Emphasize user responsibility for firewall rules on the custom agent machine itself.

IX. Update `README.md`

*   Update section "Custom Agent Nodes (Multicloud)".
*   Explain that provisioning is now automatic via SSH.
*   Detail SSH requirements (key, user, port, network path from Terraform host to custom agents).
*   Explain `ssh_private_key_path`, `ssh_use_agent`, and `os_type` options.
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
        C3 --> C3a[Installs wireguard-tools];
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
