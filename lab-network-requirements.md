# Lab Network Requirements for NICo DPU Onboarding

**Date:** 2026-09-22
**Cluster:** nico3 (apps.nico3.okoyl.xyz)
**OpenShift worker node:** ocp-qe-01.ecosys.eng.rdu2.dc.redhat.com (10.6.141.100)

---

## Summary

NICo (NVIDIA Infra Controller) manages DPUs and their host servers via automated
provisioning. The DPU data plane ports must have Layer 2 connectivity to NICo's
DHCP, PXE, and DNS services running on the OpenShift cluster. Without this, NICo
cannot provision the DPU or discover the host.

---

## Current Hardware

| Device | BMC IP | BMC Network | Data Plane MACs |
|---|---|---|---|
| BlueField-3 DPU | 10.6.136.28 | OOB management | eth0: `02:de:1f:c2:c5:11`, eth1: `02:31:dd:95:f6:18` |
| Dell PowerEdge R750 (host) | 10.6.136.44 | iDRAC management | N/A (PXE boots through DPU) |
| OpenShift worker node | 10.6.141.100 | cluster network | — |

The BMC management network (10.6.136.x) is already working — NICo can reach
both BMCs via Redfish. What's missing is the **data plane** path.

---

## Request 1: IP Allocation (3 IPs)

NICo needs **3 static IPs** on a network reachable from both the DPU data plane
ports and the OpenShift worker node (10.6.141.100). These IPs will be assigned
via MetalLB (L2 mode) to NICo's bare-metal services.

| Service | Protocol | Port | Purpose |
|---|---|---|---|
| NICo DHCP | UDP | 67/68 | Assigns IPs to DPU and host during PXE/HTTP boot |
| NICo PXE | TCP | 8080 | Serves boot images (BFB for DPU, scout.efi for host) |
| NICo DNS | UDP/TCP | 53 | Name resolution for provisioned machines |

**Requirements for the 3 IPs:**
- Must be on the same L2 segment (VLAN) as the DPU data plane ports
- Must be routable from the OpenShift worker node (10.6.141.100)
- Must not be in any existing DHCP pool (these are static, managed by MetalLB)
- Can be on the same subnet as the node IP (10.6.141.x) or a different subnet
  as long as L2 connectivity exists

Please provide the IPs in this format:

```
NICo DHCP IP:  10.x.x.___
NICo PXE IP:   10.x.x.___
NICo DNS IP:   10.x.x.___
Subnet mask:   ___.___.___.___ (e.g. 255.255.255.0)
VLAN ID:       ___ (if applicable)
```

---

## Request 2: Switch Configuration

The DPU has two 100 Gbps data plane ports (eth0, eth1) connected to the lab switch.
These ports need L2 connectivity to the OpenShift worker node where NICo services run.

### What needs to happen

```
DPU eth0 (02:de:1f:c2:c5:11) ──┐
                                ├── same VLAN / L2 segment ── OpenShift node (10.6.141.100)
DPU eth1 (02:31:dd:95:f6:18) ──┘
```

### Switch port configuration

1. **DPU data plane ports** — the switch ports connected to the DPU's eth0 and eth1
   must be on the same VLAN as (or trunked/routed to) the OpenShift worker node's network.

2. **DHCP traffic** — the DPU will send DHCP broadcasts (UDP 67/68) on this VLAN.
   NICo's DHCP server (on one of the MetalLB IPs above) must receive these broadcasts.
   If the DPU and the OpenShift node are on the **same VLAN**, this works automatically.
   If they are on **different VLANs**, a DHCP relay (ip helper-address) is needed on the
   DPU's VLAN, pointing to the NICo DHCP MetalLB IP.

3. **No port security / MAC filtering** on the DPU data plane ports — the DPU will
   bridge traffic from the host server through its data plane, so multiple MAC addresses
   will appear on the same switch port.

### Traffic flows once configured

```
                    L2 (same VLAN)
DPU eth0 ──────────────────────────────── OpenShift node
   │                                          │
   │  1. DHCP broadcast (UDP 67)              │  MetalLB VIP answers
   │  2. HTTP Boot (TCP 8080 to PXE VIP)      │  PXE serves BFB image
   │  3. DNS queries (UDP 53 to DNS VIP)      │  DNS responds
   │                                          │
   │  Later: host PXE boot goes through       │
   │  DPU bridge on same path                 │
```

---

## Request 3: Verify BMC Management Path (already working)

This is already working but listed for completeness:

| Path | Status |
|---|---|
| Cluster -> DPU BMC (10.6.136.28) via Redfish HTTPS | Working |
| Cluster -> Host BMC (10.6.136.44) via Redfish HTTPS | Working |

No changes needed on the BMC/management network.

---

## Verification After Setup

Once the switch is configured and IPs are allocated, we can verify with:

```bash
# From the OpenShift node, ping the DPU data plane (after DPU gets a DHCP lease)
# The DPU eth0 should get an IP from NICo DHCP on the allocated subnet

# From the DPU (once booted), verify it can reach the MetalLB VIPs:
ping <DHCP_VIP>
ping <PXE_VIP>
ping <DNS_VIP>
```

---

## Questions for the Lab Team

1. Which VLAN is the OpenShift worker node (10.6.141.100) on?
2. Can the DPU data plane ports be placed on the same VLAN?
3. If not the same VLAN, can a DHCP relay be configured between VLANs?
4. Are there any ACLs or port security policies that would block DHCP broadcasts
   or traffic from unknown MACs on the DPU switch ports?
5. What IP range is available for the 3 MetalLB VIPs?
