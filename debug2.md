# K3s External Hetzner Node & CCM Route Issue - Debugging Summary 2

## Core Problem
The Hetzner Cloud Controller Manager (CCM) in the main K3s cluster attempts to manage network routes for an additional Hetzner server (`ubuntu-4gb-hel1-1`). This server is intended to be an external agent node and is **not** part of the main cluster's Hetzner private network. The CCM's attempt to create routes for this external node fails because the node is not within the expected private network context.

## Primary Symptom
The `ubuntu-4gb-hel1-1` node, after joining the cluster, reports `NetworkUnavailable=True` in its status. This is because its Kubelet is started with `--cloud-provider=external`, making it reliant on the CCM to configure its routes. Since the CCM cannot properly configure routes for this external node, the node never becomes fully `Ready`. This prevents pods from being scheduled or exec'd on it.

## Investigation & Rejected Solutions
1.  **Initial Misidentification:** The node was initially thought to be a GCP VM, leading to some incorrect assumptions. Clarified that it's another Hetzner server, just not in the private network.
2.  **Global CCM Route Disablement:** Setting `HCLOUD_NETWORK_ROUTES_ENABLED="false"` in the CCM deployment would disable route management for *all* Hetzner nodes, including those correctly operating within the private network. This is not a desirable solution.
3.  **CCM Node Exclusion (Annotation/Label):** A web search for Hetzner CCM-specific annotations or labels to exclude a particular node *only* from route management did not yield a direct solution. The CCM does not appear to offer this granularity for Hetzner nodes. Standard Kubernetes annotations like `node.kubernetes.io/exclude-cloud-controller-manager-provisioning` or `csi.hetzner.cloud/manage-routes=false` were considered but their applicability or effectiveness in this specific CCM context for routes is uncertain or not documented.

## Current Proposed Solution
The most promising approach is to instruct the Kubelet on the external Hetzner node (`ubuntu-4gb-hel1-1`) *not* to wait for or rely on cloud-provider-configured routes. This can be achieved by adding the Kubelet argument:
`--configure-cloud-routes=false`

This flag tells the Kubelet that it should not expect the CCM to create routes for it. Instead, the node will rely on the CNI (Flannel, in this case, operating over public IPs via WireGuard) for its pod networking.

## Implementation Method
The `--configure-cloud-routes=false` argument should be added to the Kubelet configuration for the specific external node. In the context of the current Terraform setup, this means modifying the `kubelet_args` list for the `ubuntu-4gb-hel1-1` entry within the `custom_agent_nodepools` variable in the Terraform configuration (likely in a `.tfvars` file or similar).

**Example modification in `custom_agent_nodepools`:**
```terraform
custom_agent_nodepools = [
  {
    name             = "ubuntu-4gb-hel1-1" # Or whatever name is used in tfvars
    external_ip      = "..."
    ssh_user         = "root"
    # ... other parameters ...
    kubelet_args = [
      "--cloud-provider=external",
      "--node-ip=${local.custom_agent_nodepools["ubuntu-4gb-hel1-1"].external_ip}", # Assuming external_ip is used for node-ip
      "--node-external-ip=${local.custom_agent_nodepools["ubuntu-4gb-hel1-1"].external_ip}",
      "--configure-cloud-routes=false" # <-- Added flag
    ]
    # ... other parameters ...
  }
]
```
This change will be picked up by the `local.k3s_custom_agent_config_map` in `locals.tf`, which generates the `/etc/rancher/k3s/config.yaml` for the custom agent.

## Next Steps
1.  Apply the Kubelet argument change in the Terraform configuration.
2.  Run `terraform apply` to update the K3s configuration on the `ubuntu-4gb-hel1-1` node and restart the K3s agent.
3.  Verify the node becomes `Ready` and the `NetworkUnavailable` condition is cleared.
4.  Test pod scheduling and `kubectl exec` on the `ubuntu-4gb-hel1-1` node. 