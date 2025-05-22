# Plan to Resolve K3s Node Disappearance and Refine Networking for Mixed Networks & Autoscalers
# This plan focuses on specific K3s flag adjustments, particularly for `flannel-iface` and autoscaled nodes,
# complementary to the broader "Custom Agent Nodes" provisioning detailed in `multicloud_agents_plan.md`.

## 1. Problem Summary

Custom agent nodes, external to the Hetzner private network (e.g., VMs in GCP/AWS), appear briefly in `kubectl get nodes` after being added to the cluster but then disappear. Log analysis on these custom agents revealed a fatal error: `level=fatal msg="flag provided but not defined: -flannel-external-ip"`. This indicates that the `flannel-external-ip` K3s flag, which was being incorrectly applied to agents, is a server-only flag.

The broader issue is that the networking configuration for Flannel needs to be correctly adjusted across all node types to support a mixed public/private IP environment. This document outlines crucial flag settings, while `multicloud_agents_plan.md` covers the overall custom agent integration and CNI strategy.

## 2. Core K3s Networking Principles for Flannel in Mixed Networks

To ensure Flannel works correctly when nodes are on different networks (some on Hetzner private network, some external with only public IPs), the following K3s flags and configurations are key:

*   **`--flannel-external-ip=true`**:
    *   This is a **K3s Server (Control Plane) only flag**.
    *   It instructs the K3s server to use the external IP addresses of all nodes for Flannel overlay network communication. The implementation of this flag is covered in `multicloud_agents_plan.md`.
*   **`--node-external-ip=<node_public_IP>`**:
    *   This flag must be used by **all nodes** (servers and agents).
    *   Each node uses this to advertise its actual public IP address. The implementation of this flag is covered in `multicloud_agents_plan.md`.
*   **`--node-ip=<node_primary_IP>`**:
    *   Used by all nodes.
    *   For Hetzner-based nodes (Control Planes and Agents), this should be their **private IP address** (on `eth1`).
    *   For custom external agents that do not have a separate private IP relevant to the cluster's internal networking, this can be set to their public IP address (same as `--node-external-ip`).
*   **`--flannel-iface=<interface_name>`**:
    *   This is a K3s Agent flag that can also be set on Servers (as they also run an agent component).
    *   In a mixed-network setup where external nodes cannot reach the private interfaces of Hetzner nodes (like `eth1`), and when `--flannel-external-ip=true` is active on the servers, this flag **must be omitted (or set to null/empty string) for all nodes**. This allows Flannel to default to using the IPs provided by `--node-external-ip` for communication.
*   **Flannel Node Annotations**:
    *   K3s, when configured with `--flannel-external-ip=true` on the server and when nodes use `--node-external-ip`, automatically manages the necessary Flannel annotations on the Node objects. There is no need to manually manage these annotations.

## 3. Key Terraform Changes (Focus on `flannel-iface` and Autoscalers)

The following modifications are primarily focused on `flannel-iface` logic and specific needs of autoscaled agents, complementing the broader changes detailed in `multicloud_agents_plan.md`.

### A. `locals.tf`

1.  **Modify `local.flannel_iface`**:
    *   **Current (Conceptual):** `flannel_iface               = "eth1"`
    *   **Proposed Change:** Make `flannel_iface` conditional. If custom agents are used (i.e., `local.enable_multicloud_agents` as defined in `multicloud_agents_plan.md` is true), this should be `null`.
        ```terraform
        flannel_iface = local.enable_multicloud_agents ? null : "eth1"
        ```
    *   **Rationale:** This ensures that when custom external agents are present, Hetzner nodes (CPs and regular Agents) do not try to force Flannel traffic over their private `eth1` interface, which external nodes cannot reach. Instead, they will rely on their `--node-external-ip`.

### B. `control_planes.tf`

1.  **`flannel-iface`**:
    *   This will be correctly handled by the modification to `local.flannel_iface` in `locals.tf`.
2.  **`node-ip`**:
    *   The logic `node-ip = module.control_planes[k].private_ipv4_address` remains **CORRECT**. Hetzner control planes continue to use their private IP for this parameter.
3.  Other flags such as `flannel-external-ip` and `node-external-ip` are addressed by the changes outlined in `multicloud_agents_plan.md`.

### C. `agents.tf`

1.  **`flannel-iface`**:
    *   This will be correctly handled by the modification to `local.flannel_iface` in `locals.tf`.
2.  **`node-ip`**:
    *   The logic `node-ip = module.agents[k].private_ipv4_address` remains **CORRECT**. Hetzner agents continue to use their private IP for this parameter.
3.  Other flags such as `node-external-ip` are addressed by the changes outlined in `multicloud_agents_plan.md`.

### D. `autoscaler-agents.tf` (Critical Adjustments for Multicloud)

The K3s configuration for autoscaled Hetzner agents requires specific handling for multicloud scenarios, particularly for IP and interface settings.

1.  **`flannel-iface` in Cloud-Init `k3s_config`**:
    *   The `k3s_config` map passed to the `autoscaler-cloudinit.yaml.tpl` template needs to use the revised `local.flannel_iface`.
        ```terraform
        // In autoscaler-agents.tf, when defining the k3s_config map for the template
        k3s_config = yamlencode({
          # ... other existing parameters ...
          flannel-iface = local.flannel_iface, // Relies on modified local.flannel_iface (will be null if multicloud)
          # ... node-external-ip and node-ip are handled via CLI args below ...
        })
        ```
    *   The `k3s_config` is generated by Terraform *before* the autoscaled node exists, so its specific public/private IPs cannot be known for `node-external-ip` or `node-ip` at this stage. These must be passed as K3s agent CLI arguments.

2.  **`node-external-ip` and `node-ip` for Autoscaled Agents (via CLI arguments)**:
    *   These are **currently missing** as explicit CLI arguments in the install script for a multicloud scenario.
    *   **Proposed Change:** Modify the `install_k3s_agent_script` content within `autoscaler-cloudinit.yaml.tpl` (or `local.install_k3s_agent` if that's the primary source for `INSTALL_K3S_EXEC` for autoscalers).
        *   The `INSTALL_K3S_EXEC` string in the script should be augmented when `local.enable_multicloud_agents` is true:
            ```bash
            # Example of how the INSTALL_K3S_EXEC string could be formed in Terraform locals or the template
            # This is conceptual for the script executed on the node:
            PUBLIC_IP=$(curl -sfL ifconfig.me || ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1) # Fallback if ifconfig.me fails
            PRIVATE_IP=$(ip -4 addr show eth1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
            INSTALL_K3S_EXEC="agent \
                              ${var.k3s_exec_agent_args} \
                              --node-ip=$PRIVATE_IP \
                              $(local.enable_multicloud_agents ? "--node-external-ip=$PUBLIC_IP" : "") \
                              # Other args..."
            # ... rest of install script ...
            ```
        *   This requires making `local.enable_multicloud_agents` available to the template or constructing the agent exec string conditionally in `locals.tf` and passing it to the template.
        *   Ensure `curl` is available on autoscaled nodes, or use a more robust IP discovery method.

### E. `custom_agent_provisioning.tf`
*   The configuration and provisioning of custom external agents are comprehensively covered in `multicloud_agents_plan.md`.

## 4. Expected Impact

*   **Stable Custom Agent Nodes:** Custom external agent nodes should join and remain part of the cluster, as the K3s agent will start correctly without invalid flags and with proper network interface configuration.
*   **Correct Flannel Operation:** Flannel should establish its overlay network using the public IP addresses of all nodes (Hetzner CPs, Hetzner Agents, Custom Agents, and Autoscaled Hetzner Agents) when custom agents are part of the cluster.
*   **No Impact on Single-Cloud (Hetzner-only) Deployments:** When `var.custom_agent_nodepools` is empty (making `local.enable_multicloud_agents` false), the networking configuration will revert to using `flannel-iface: eth1`, maintaining the existing behavior for Hetzner-only clusters.

## 5. Important Considerations for these Specific Changes

*   **Prerequisites from `multicloud_agents_plan.md`**: This plan assumes that WireGuard installation on all relevant nodes, necessary firewall rules (on Hetzner Cloud and on custom nodes), and the overall CNI strategy (e.g., forcing Flannel to `wireguard-native` backend when `local.enable_multicloud_agents` is true) are implemented as detailed in `multicloud_agents_plan.md`.
*   **IP Discovery on Autoscaled Nodes:** The method chosen to discover the public and private IP addresses for autoscaled nodes (`curl -sfL ifconfig.me` and `ip addr show eth1`) must be reliable, and the necessary tools (`curl`, `ip`) must be available in the OS image used for these nodes.
*   **Atomicity of Changes:** Applying these changes will likely involve recreation or reconfiguration of existing nodes by Terraform if their K3s configuration files or startup scripts change. This could lead to temporary unavailability of nodes during the update.
*   **CNI Plugin Focus:** While this document's `flannel-iface` discussion is specific to Flannel, the principles of nodes advertising their external IPs (`--node-external-ip`) are generally applicable. Detailed configurations for other CNIs like Calico or Cilium in a multicloud context are provided in `multicloud_agents_plan.md`.

This refined plan provides a focused approach to critical Flannel flag settings and autoscaler networking, ensuring it complements the main multicloud agent provisioning strategy. 