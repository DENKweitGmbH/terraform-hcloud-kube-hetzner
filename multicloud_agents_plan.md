Refactored Plan to Implement "Custom Agent Nodes" Feature

Core Principle: The presence of a non-empty `custom_agent_nodepools` list in the user's `kube.tf` will implicitly activate the "multicloud agents" feature, enforcing WireGuard for CNI communication.

I. Introduce New Terraform Variables (in `variables.tf`)

1.  `custom_agent_nodepools`:
    *   Type: `list(object({ ... }))`
    *   Default: `[]`
    *   Description: "A list of objects defining pre-existing custom agent nodes to be integrated into the cluster. Defining this list automatically enables multicloud agent mode. Terraform will output configuration and installation scripts for these nodes."
    *   Object attributes:
        *   `name`: (string, required) A unique name for the custom agent (e.g., "my-external-server").
        *   `external_ip`: (string, required) The public IP address of the custom agent machine.
        *   `ssh_user`: (string, optional, e.g., "ubuntu") The SSH user for the custom machine (for user instructions).
        *   `ssh_port`: (number, optional, default: 22) The SSH port for the custom machine (for user instructions).
        *   `labels`: (list(string), optional) K3s node labels.
        *   `taints`: (list(string), optional) K3s node taints.

2.  `wireguard_udp_port`:
    *   Type: `number`
    *   Default: `51820`
    *   Description: "The UDP port for WireGuard tunnels used by Flannel, Calico, or Cilium. This port is automatically opened on Hetzner firewalls when `custom_agent_nodepools` is defined or `enable_wireguard` is true. Users must ensure this port is open on their custom agents."

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
        *   If `local.enable_multicloud_agents` is true, CP K3s args/config: Add `flannel-external-ip = ""`.

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

V. Create `custom_agents_outputs.tf` (New File)

*   Output `custom_agent_configurations` containing `config_yaml_content`, `install_script`, and detailed user instructions for each custom agent node.
    ```terraform
    output "custom_agent_configurations" {
      description = "Provides the k3s agent configuration and installation script for each custom agent node. Apply these on your external machines."
      value = {
        for name, agent_details in var.custom_agent_nodepools : name => {
          config_yaml_content = local.k3s_custom_agent_config_map[name]
          install_script      = local.k3s_custom_agent_install_script_map[name]
          instructions        = <<-EOT
            To provision custom agent '${name}' (IP: ${agent_details.external_ip}):
            1. SSH into your custom machine (e.g., ssh ${coalesce(agent_details.ssh_user, "root")}@${agent_details.external_ip} -p ${coalesce(agent_details.ssh_port, 22)}).
            2. Ensure the WireGuard UDP port ${var.wireguard_udp_port} (default 51820) is open for inbound traffic on this machine's firewall.
            3. If using Calico or Cilium CNI, ensure WireGuard tools (e.g., `wireguard-tools` package) are installed.
            4. Create the k3s configuration directory: sudo mkdir -p /etc/rancher/k3s
            5. Create the configuration file: sudo nano /etc/rancher/k3s/config.yaml
               Paste the following content into the file:
               ---
               ${local.k3s_custom_agent_config_map[name]}
               ---
            6. Set correct permissions: sudo chmod 0600 /etc/rancher/k3s/config.yaml
            7. Run the installation script:
               ${local.k3s_custom_agent_install_script_map[name]}
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
    ```

VI. Modify `main.tf` (Firewall Rules in `locals.tf`)

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

VII. Update `kube.tf.example`

*   Add the `custom_agent_nodepools` variable with an example.
*   Add the `wireguard_udp_port` variable, commented out, showing its default value (51820).
*   Add comments explaining:
    *   Defining `custom_agent_nodepools` automatically enables multicloud mode and enforces secure CNI communication (using WireGuard) for all nodes.
    *   How the `control_plane_external_api_endpoint` is determined for external agents (uses LB public IP if `use_control_plane_lb=true`, else first CP public IP; `kubeconfig_server_address` can be used as an override).
    *   The `wireguard_udp_port` (default 51820) will be opened on Hetzner firewalls; users must open this on their custom agents' firewalls.
    *   For Cilium CNI: If `custom_agent_nodepools` is defined, `routingMode` will be forced to "tunnel" and WireGuard encryption will be enabled, irrespective of `var.cilium_routing_mode` or `var.enable_wireguard` settings.

VIII. Update `README.md`

*   New section "Custom Agent Nodes (Multicloud)".
*   Explain that the feature is enabled by defining `custom_agent_nodepools`.
*   Detail how WireGuard is implicitly enabled for CNI for all nodes when this feature is active.
*   Detail how the `control_plane_external_api_endpoint` is derived and how `var.kubeconfig_server_address` can influence it.
*   Reiterate networking implications (public CP API, all k3s CNI traffic over external IPs/tunnels, WireGuard UDP port firewall requirements for *all* nodes including custom nodes).
*   Mention the `wireguard_udp_port` variable and its default.
*   Document the CNI-specific behaviors (Flannel `wireguard-native`, Calico `FELIX_WIREGUARDENABLED=true`, Cilium `routingMode="tunnel"` and WireGuard encryption forced).
*   Reference `custom_agent_configurations` output for provisioning custom nodes.

This updated plan makes the feature more secure by default and simplifies configuration by leveraging existing WireGuard capabilities and sensible defaults.

```terraform
output "custom_agent_configurations" {
  description = "Provides the k3s agent configuration and installation script for each custom agent node. Apply these on your external machines."
  value = {
    for name, agent_details in var.custom_agent_nodepools : name => {
      config_yaml_content = local.k3s_custom_agent_config_map[name]
      install_script      = local.k3s_custom_agent_install_script_map[name]
      instructions        = <<-EOT
        To provision custom agent '${name}' (IP: ${agent_details.external_ip}):
        1. SSH into your custom machine (e.g., ssh ${coalesce(agent_details.ssh_user, "root")}@${agent_details.external_ip} -p ${coalesce(agent_details.ssh_port, 22)}).
        2. Ensure the WireGuard UDP port ${var.wireguard_udp_port} (default 51820) is open for inbound traffic on this machine's firewall.
        3. If using Calico or Cilium CNI, ensure WireGuard tools (e.g., `wireguard-tools` package) are installed.
        4. Create the k3s configuration directory: sudo mkdir -p /etc/rancher/k3s
        5. Create the configuration file: sudo nano /etc/rancher/k3s/config.yaml
           Paste the following content into the file:
           ---
           ${local.k3s_custom_agent_config_map[name]}
           ---
        6. Set correct permissions: sudo chmod 0600 /etc/rancher/k3s/config.yaml
        7. Run the installation script:
           ${local.k3s_custom_agent_install_script_map[name]}
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
```

## Conceptual Flow Diagram

```mermaid
graph LR
    A[User enables `enable_multicloud_agents` and defines `custom_agent_nodepools` in kube.tf] --> B{Terraform Plan/Apply};

    subgraph Terraform Execution
        B --> C1[Modifies CP k3s config: adds --node-external-ip, --flannel-external-ip];
        B --> C2[Modifies Hetzner Agent k3s config: sets server to Public LB IP, adds --node-external-ip];
        B --> C3[Generates k3s config & install script for Custom Agents];
        B --> C4[Updates Hetzner Firewall: opens WireGuard UDP port];
    end

    C3 --> D[Outputs Custom Agent config & script];
    D --> E[User manually provisions Custom Agents using outputs];

    subgraph Kubernetes Cluster
        F[Hetzner Control Planes (Public IPs for k3s, Private for etcd)]
        G[Hetzner Agents (Public IPs for k3s)]
        H[Custom Agents (Public IPs for k3s)]

        F -- "k3s API (via Public LB IP)" --> G;
        F -- "k3s API (via Public LB IP)" --> H;
        G -- "CNI (WireGuard over Public IPs)" --> H;
        G -- "CNI (WireGuard over Public IPs)" --> F;
        H -- "CNI (WireGuard over Public IPs)" --> F;
    end

    style A fill:#lightgrey,stroke:#333
    style B fill:#lightblue,stroke:#333
    style E fill:#lightgreen,stroke:#333
```
