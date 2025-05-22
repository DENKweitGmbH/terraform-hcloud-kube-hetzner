# K3s Custom GCP Agent Debugging Summary

## Core Symptom

A custom GCP agent node (e.g., `gcp-agent-1337-1`) successfully registers with the Hetzner-based K3s control plane, appears briefly in `kubectl get nodes`, but then disappears. This behavior was consistently observed even after a full cluster recreation.

## Key Observations & Findings

### Agent Node (`gcp-agent-1337-1`)
*   **Initial Logs:**
    *   Repeated "Error getting the current node from lister" err="node "gcp-agent-1337-1" not found".
    *   "Failed to initialize CSINode: error updating CSINode annotation: timed out waiting for the condition; caused by: nodes "gcp-agent-1337-1" not found".
*   **Later Logs:** `k3s-agent` service exits with `status=2/INVALIDARGUMENT` during `csi.initializeCSINode`.
*   **Terraform Provisioning:** `remote-exec` provisioner completes successfully.
*   **Connectivity:**
    *   TCP/TLS connectivity to control plane's public IP (`188.245.225.19:6443`) confirmed (e.g., `curl https://<SERVER_IP>:6443/livez` returns `401 Unauthorized`, which is expected).
*   **`wg show` on GCP Agent:**
    *   Lists the K3s server (`188.245.225.19`) as a peer.
    *   Shows a recent handshake and small data transfer.
*   **`tcpdump` on GCP Agent (UDP 51820):**
    *   Shows handshake packets exchanged with the K3s server.

### K3s Server / Control Plane (`denkcluster-control-plane-fsn1-cqu`)
*   **IP Addresses:** Public `188.245.225.19`, Private `10.255.0.101` (on `eth1`).
*   **K3s Server Logs (`-v=5`):**
    *   Certificates signed for `gcp-agent-1337-1`.
    *   PodCIDR allocated to the agent (e.g., `10.42.9.0/24`).
    *   Flannel (WireGuard backend) adds a subnet for the agent: `Subnet added: 10.42.9.0/24 via 157.180.118.0:51820`.
    *   Almost immediately after subnet addition: `Failed to update statusUpdateNeeded field ... because nodeName="gcp-agent-1337-1" does not exist`.
    *   Then: `Subnet removed: 10.42.9.0/24`.
    *   This cycle (cert sign, PodCIDR alloc, subnet add, node not exist, subnet remove) repeats.
    *   The node is recognized and a network path is attempted for ~2.5 seconds before being torn down.
*   **`wg show` on K3s Server:**
    *   **Crucially, does NOT list the GCP agent (`157.180.118.0`) as a peer.**
*   **`tcpdump` on K3s Server (UDP 51820):**
    *   Shows handshake packets exchanged with the GCP agent.
*   **Node Annotations:**
    *   Control plane node has `flannel.alpha.coreos.com/public-ip: "188.245.225.19"`.
    *   When the GCP agent briefly joins, it also gets a correct `flannel.alpha.coreos.com/public-ip: "157.180.118.0"` annotation.
*   **Control Plane Stability (Observed Before Full Recreate, Unknown if Persists):**
    *   OCI runtime/cgroup errors: `OCI runtime create failed: runc create failed: expected cgroupsPath to be of format "slice:prefix:name" for systemd cgroups...`
    *   `cluster-autoscaler` pod was in `CrashLoopBackOff`.
    *   The control plane was reportedly running on a Btrfs read-only snapshot. This was suspected as a cause for runtime issues.

## K3s Configuration Details
*   **Key Flags:**
    *   `--flannel-external-ip=true` (Server only)
    *   `--node-external-ip=<node's_public_ip>` (Set on all nodes, including control plane and agents)
*   **Flannel Backend:** `wireguard-native` (specified in `/etc/rancher/k3s/config.yaml` on the server).
*   **`flannel-iface`:**
    *   Initially was `eth1` on the control plane.
    *   Manually changed to `null` on the control plane. The intention is that when `flannel-external-ip=true` is used, `flannel-iface` should not be set (or be `null`) for Flannel to correctly use the `--node-external-ip`.
    *   The `locals.tf` was previously (and potentially still is, after recreate) incorrectly trying to set `flannel-iface` on agents when `flannel-external-ip` was true, this was being corrected.
*   **MTU:** `flannel-wg` interfaces on both server and agent show `mtu 1420`. `eth0` on both is `1500`.

## Primary Hypothesis

The K3s server, despite receiving initial WireGuard handshake packets from the GCP agent and attempting to add a Flannel subnet for it, fails to establish or maintain the WireGuard peer relationship with the GCP agent. This is evidenced by the GCP agent not appearing in the server's `wg show` output. Consequently, the server considers the agent node "not found" shortly after registration, leading to the agent's removal from the cluster and the teardown of its allocated network resources (PodCIDR, Flannel subnet).

The persistence of this issue after a full cluster recreation suggests a misconfiguration in the Terraform provisioning, K3s startup scripts, or an inherent networking challenge in the hybrid cloud setup that the current K3s/Flannel flags are not correctly addressing.

## Next Steps Considered
*   Verify if control plane instability (cgroup errors) persists after cluster recreation.
*   Investigate deeper into K3s server-side WireGuard configuration and Flannel interactions.
*   Consider alternative CNI or Flannel backends if WireGuard issues prove intractable in this hybrid setup.
*   Examine any potential GCP-side network policies or firewalls that might interfere with sustained WireGuard communication beyond the initial handshake (though `tcpdump` showing bidirectional handshakes makes this less likely as the sole cause). 