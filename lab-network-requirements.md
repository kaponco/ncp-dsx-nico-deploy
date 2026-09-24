# Lab Network Requirements for NICo DPU Onboarding

**Date:** 2026-09-24
**Cluster:** nico3 (apps.nico3.okoyl.xyz) — Single-Node OpenShift (SNO)
**OpenShift node:** ocp-qe-01.ecosys.eng.rdu2.dc.redhat.com (10.6.141.100)
**Host server:** nvd-srv-06.nvidia.eng.rdu2.dc.redhat.com (DPU installed here)

---

## Summary

NICo (NVIDIA Infra Controller) manages DPUs and their host servers via automated
provisioning. The DPU data plane ports must have Layer 2 connectivity to NICo's
DHCP, PXE, and DNS services running on the OpenShift cluster. Without this, NICo
cannot provision the DPU or discover the host.

**Critical:** NICo runs its own DHCP server. The DPU data plane must be on a
VLAN where **only NICo's DHCP** responds — not the lab DHCP. If both DHCP servers
are on the same L2 segment, they race and the DPU may boot with the wrong
configuration. This is why we need a **dedicated VLAN** for the DPU data plane.

---

## Current Hardware

### Data plane — NEEDS DEDICATED VLAN (this request)

These interfaces must be on a **dedicated VLAN** where NICo is the only DHCP
server. The OpenShift node must also have a presence on this VLAN (via a trunk
port or second NIC) so MetalLB can announce the VIP.

| Device | Interface | MAC | Switch port action |
|---|---|---|---|
| BlueField-3 DPU | eth0 (100G) | `02:de:1f:c2:c5:11` | Access port on dedicated VLAN |
| BlueField-3 DPU | eth1 (100G) | `02:31:dd:95:f6:18` | Access port on dedicated VLAN |
| OpenShift node (SNO) | eth0.VLAN (tagged) | 10.6.141.100 | Trunk port: add dedicated VLAN (tagged) |
| MetalLB VIP | — | (to be allocated) | Announced from OpenShift node on this VLAN |

The host server has no direct NIC on this VLAN — it PXE boots **through the
DPU bridge** on eth0, so additional MACs (the host NIC) will appear on the
DPU's switch port.

### Management plane — ALREADY WORKING (no changes needed)

| Device | Interface | MAC | IP | Status |
|---|---|---|---|---|
| BlueField-3 DPU | oob0 (BMC) | `a0:88:c2:75:91:8e` | 10.6.136.28 | Working |
| BlueField-3 DPU | BMC Manager | `a0:88:c2:75:91:8f` | 10.6.136.28 | Working |
| Dell PowerEdge R750 | iDRAC | `c8:4b:d6:86:f3:a0` | 10.6.136.44 | Working |

NICo reaches both BMCs via Redfish over this network. No changes needed.
BMCs stay on 10.6.136.x — they are **not** on the DPU data plane VLAN.

---

## Request 1: Dedicated VLAN + IP Allocation

### Why a dedicated VLAN

The OpenShift node is currently on VLAN 520 (10.6.141.0/24), which has a lab
DHCP server. NICo runs its own DHCP server to assign IPs and boot URIs to
DPUs and hosts during provisioning. If the DPU data plane ports are placed on
VLAN 520, both DHCP servers respond to the DPU's requests — whichever answers
first wins. If the lab DHCP wins, the DPU gets no boot URI, HTTP Boot fails,
and NICo cannot provision it.

A dedicated VLAN ensures NICo's DHCP is the **only** DHCP server the DPU sees.

### What we need

1. **A new VLAN** (or an existing one with no DHCP server) for the DPU data plane
2. **A small subnet** on that VLAN (even a /28 is enough)
3. **1 static IP** on that subnet for the MetalLB VIP — not in any DHCP pool
4. **The OpenShift node's switch port trunked** to carry this VLAN (tagged),
   in addition to VLAN 520 (untagged/native, existing)

The VIP will be shared (via MetalLB L2 mode) across all NICo services — they
use different ports so there is no conflict:

| Service | Protocol | Port | Purpose | Required |
|---|---|---|---|---|
| NICo DHCP | UDP | 67/68 | Assigns IPs to DPU and host during PXE/HTTP boot | Yes |
| NICo PXE | TCP | 8080, 80 | Serves boot images (BFB for DPU, scout.efi for host) | Yes |
| NICo DNS | UDP/TCP | 53 | Name resolution for provisioned machines | Yes |
| NICo API | TCP | 443 | Core gRPC API — DPU agent registers after boot | Yes |
| NICo SSH Console | TCP | 22 | Operator console access to DPU/host | Optional |

Please provide:

```
VLAN ID:       ___
Subnet:        10.x.x.0/___
NICo VIP:      10.x.x.___
Subnet mask:   ___.___.___.___ (e.g. 255.255.252.0)
Gateway:       10.x.x.___ (for routing back to 10.6.141.x and 10.6.136.x)
```

---

## Request 2: Switch Configuration

### Network topology

```
                VLAN 520 (10.6.141.x)              Dedicated VLAN (new)
                existing, lab DHCP                  NICo DHCP only
               ┌─────────────────────┐            ┌─────────────────────┐
               │ Lab hosts           │            │                     │
               │ Lab DHCP server     │            │ DPU eth0            │
               │                     │            │ DPU eth1            │
               │ OpenShift node ─────┼── trunk ───┼── MetalLB VIP      │
               │  (10.6.141.100)     │            │  (NICo services)    │
               └─────────────────────┘            └─────────────────────┘
                        │ routed
               ┌─────────────────────┐
               │ BMC network         │
               │ (10.6.136.x)        │
               │ DPU BMC, Host iDRAC │
               └─────────────────────┘
```

### Switch port configuration

1. **OpenShift node switch port** — trunk port carrying:
   - VLAN 520 (untagged/native) — existing cluster traffic, no change
   - Dedicated VLAN (tagged) — new, for DPU data plane + MetalLB VIP

2. **DPU eth0 and eth1 switch ports** — access ports on the dedicated VLAN:
   - MAC `02:de:1f:c2:c5:11` (eth0)
   - MAC `02:31:dd:95:f6:18` (eth1)

3. **No port security / MAC filtering** on the DPU switch ports — the DPU
   bridges traffic from the host server through its data plane, so multiple
   MAC addresses will appear on the same switch port.

4. **No DHCP snooping** on the dedicated VLAN, or if enabled, mark the
   OpenShift node's port as a trusted DHCP source (NICo's DHCP runs there).

5. **Routing** — the dedicated VLAN needs a gateway that can route to:
   - 10.6.141.0/24 (cluster network, for return traffic to OpenShift)
   - 10.6.136.0/24 (BMC network — optional, useful for debugging)

### Traffic flows once configured

```
                 Dedicated VLAN (L2)
DPU eth0 ──────────────────────────────── OpenShift node (tagged)
   │                                          │
   │  1. DHCP broadcast (UDP 67)              │  MetalLB VIP answers
   │  2. HTTP Boot (TCP 8080 to VIP)          │  PXE serves BFB image
   │  3. DNS queries (UDP 53 to VIP)          │  DNS responds
   │  4. gRPC register (TCP 443 to VIP)       │  Core API accepts agent
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

## OpenShift Node Configuration (our side, after lab completes above)

Once the lab team provides the VLAN ID and subnet, we will:

1. Configure a VLAN-tagged subinterface on the OpenShift node (e.g. `eth0.XXX`)
2. Install the MetalLB operator and configure an IPAddressPool with the VIP
3. Redeploy NICo site services with `make deploy-site SITE_VIP=<allocated-ip>`

---

## Verification After Setup

Once the switch is configured and the VIP is allocated, we can verify with:

```bash
# From the OpenShift node, verify the VLAN subinterface is up
ip addr show eth0.<VLAN_ID>

# From a pod on the dedicated VLAN, verify MetalLB VIP is reachable
ping <VIP>

# After DPU gets a DHCP lease from NICo, verify from the DPU:
ping <VIP>
curl http://<VIP>:8080   # PXE service
dig @<VIP> example.com   # DNS service
```

---

## Questions for the Lab Team

1. What VLAN ID and subnet can be allocated for the dedicated DPU data plane VLAN?
2. Can the OpenShift node's switch port (ocp-qe-01) be converted to a trunk
   carrying VLAN 520 (native) + the new VLAN (tagged)?
3. Is there a gateway on the new VLAN that routes to 10.6.141.0/24 and 10.6.136.0/24?
4. Are there any ACLs or port security policies that would block DHCP broadcasts
   or traffic from unknown MACs on the DPU switch ports?
