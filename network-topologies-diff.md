# Network Topologies: Flat vs Leaf/Spine (eBGP)

A practical guide to understanding datacenter network topologies and how they
relate to NICo deployment modes.

## Table of Contents

- [Flat Network Topology](#flat-network-topology)
- [Leaf/Spine with eBGP](#leafspine-with-ebgp)
- [eBGP Unnumbered — Why It Matters](#ebgp-unnumbered--why-it-matters)
- [NVIDIA Spectrum Switch Capabilities](#nvidia-spectrum-switch-capabilities)
- [North-South Communication](#north-south-communication)
- [East-West Communication](#east-west-communication)
- [VXLAN/EVPN Overlay — The DPU Story](#vxlanevpn-overlay--the-dpu-story)
- [How This Maps to NICo](#how-this-maps-to-nico)

---

## Flat Network Topology

"Flat" means all hosts sit in the **same L2 broadcast domain** — one big
subnet, typically with a single default gateway. Every device can reach every
other device via L2 (Ethernet frames, ARP, broadcast).

```
            ┌──────────────┐
            │   Internet   │
            └──────┬───────┘
                   │
            ┌──────┴───────┐
            │  Core Router │  ← single default gateway for all hosts
            └──────┬───────┘
                   │
            ┌──────┴───────┐
            │   L2 Switch  │  ← or a stack of switches (L2 trunk/access)
            ├──┬──┬──┬──┬──┤
            H1 H2 H3 H4 H5   ← all hosts in 10.0.0.0/24
```

### How it works

- All hosts share one subnet (e.g., `10.0.0.0/24`) with one gateway
  (`10.0.0.1`)
- Switches forward traffic based on MAC addresses (L2 forwarding tables)
- ARP broadcasts reach every host on the segment
- Redundant links are managed by **Spanning Tree Protocol (STP)** — which
  blocks redundant paths to prevent loops

### What you get

- **Simple** — one subnet, one gateway, cheap switches, minimal config
- **Easy troubleshooting** — everything is on the same segment, `tcpdump` sees
  all
- **Good for small environments** — labs, PoCs, small deployments (< ~200 hosts)

### What breaks at scale

| Problem | Why it hurts |
|---|---|
| **Broadcast storms** | Every ARP request hits every host — grows with host count |
| **Single failure domain** | One misconfigured host or loop affects the entire L2 domain |
| **No isolation** | All hosts share the same broadcast domain — no tenant separation |
| **STP blocks links** | Redundant links are disabled to prevent loops — wasted bandwidth |
| **Limited scale** | Practically tops out at a few hundred hosts |
| **Unpredictable latency** | Traffic may take suboptimal paths due to STP topology |

---

## Leaf/Spine with eBGP

This is the **datacenter-standard architecture** used by hyperscalers and
modern enterprise datacenters. The key design principle: **every link is L3
(routed), no spanning tree, no shared broadcast domain.**

```
            ┌──────────────┐
            │   Internet   │
            └──────┬───────┘
                   │
         ┌─────────┴──────────┐
         │   Border Leaf (BL) │  ← north-south gateway, external peering
         └────┬──────────┬────┘
              │          │
        ┌─────┴──┐  ┌───┴─────┐
        │ Spine1 │  │ Spine2  │   ← every spine connects to every leaf
        └┬──┬──┬─┘  └─┬──┬──┬─┘
         │  │  │      │  │  │
         │  │  └──────│──│──│───── eBGP sessions (point-to-point, routed L3)
         │  │         │  │  │
       ┌─┴──┴─┐   ┌──┴──┴─┐
       │ Leaf1 │   │ Leaf2 │     ← Top-of-Rack (ToR) switches
       ├──┬──┬─┤   ├──┬──┬─┤
       H1 H2 H3   H4 H5 H6     ← each leaf owns its own L2/L3 domain
      10.1.1/24   10.1.2/24
```

### Terminology

| Term | Meaning |
|---|---|
| **Leaf** | Top-of-Rack (ToR) switch — connects directly to hosts. Each leaf is its own L2 domain |
| **Spine** | Aggregation layer — connects all leaves together. Carries no hosts directly |
| **Border Leaf** | Special leaf that peers with external routers (internet, WAN, other DCs) |
| **eBGP** | External BGP — routing protocol where each device has its own ASN |
| **ECMP** | Equal-Cost Multi-Path — traffic uses ALL spine paths simultaneously |
| **ASN** | Autonomous System Number — unique identifier per device in BGP |

### How it works

1. Each leaf and spine gets its own BGP ASN
2. Every link between leaf↔spine runs an eBGP session
3. Each leaf advertises its host subnets to the spines
4. Spines propagate routes to all other leaves
5. Traffic between racks takes the shortest path through any available spine
   (ECMP)

### What you get

| Benefit | Detail |
|---|---|
| **All links active** | ECMP uses every spine simultaneously — no STP blocking |
| **Fault isolation** | A problem on Leaf1 does NOT affect Leaf2 |
| **Predictable latency** | Max 3 L3 hops for any east-west traffic (leaf → spine → leaf) |
| **Linear scale** | Add more leaves for hosts, more spines for bandwidth |
| **Per-rack failure domain** | Each leaf/rack is independent |
| **Sub-second failover** | BFD (Bidirectional Forwarding Detection) detects link failures in ms |

### Scaling example

```
2 spines × 48 ports = 48 leaves possible
48 leaves × 48 host ports = 2,304 hosts
Need more? Add spine tier or increase port density.
```

---

## eBGP Unnumbered — Why It Matters

Traditional BGP requires configuring IP addresses on every point-to-point link.
In a leaf/spine fabric with hundreds of links, this becomes operationally
painful:

```
# Traditional eBGP — manual IP assignment on every link
interface eth1
  ip address 10.0.1.0/31
neighbor 10.0.1.1 remote-as 65001

interface eth2
  ip address 10.0.2.0/31
neighbor 10.0.2.1 remote-as 65002

# ... repeat for every single link (hundreds of them)
```

**eBGP unnumbered** (RFC 5549) eliminates this entirely. It uses **IPv6
link-local addresses** (auto-generated on every interface, no config needed) and
carries IPv4 routes over them:

```
# eBGP unnumbered — just declare the interfaces
interface swp1
  neighbor swp1 remote-as external    ← auto-discovers peer ASN

interface swp2
  neighbor swp2 remote-as external    ← same for every port

# That's it. No IP planning, no subnet allocation for inter-switch links.
```

**Why NICo requires this:** The DPU's uplinks to the ToR switch are configured
as eBGP unnumbered in the NVUE template. The DPU expects to peer with whatever
switch is on the other end using IPv6 link-local + RFC 5549. A switch that
doesn't support this cannot peer with the DPU.

---

## NVIDIA Spectrum Switch Capabilities

Spectrum is the ASIC inside NVIDIA's datacenter switches (SN2000/3000/4000/5000
series), running either **Cumulus Linux** (traditional) or **NVOS** (newer).

### Spectrum vs Standard Enterprise Switches

| Capability | Standard enterprise switch | NVIDIA Spectrum |
|---|---|---|
| eBGP unnumbered (RFC 5549) | Rarely supported | Native, zero-config |
| ECMP paths | 4–8 typical | 64–128 (in hardware) |
| Line-rate L3 routing | Often software at scale | Full hardware, every port |
| BGP convergence | Seconds | Sub-second (BFD offloaded to hardware) |
| VXLAN encap/decap | Software or not supported | Hardware line-rate |
| EVPN (L2/L3 overlay) | Limited or absent | Full Type-2/Type-5 in hardware |
| ACL / firewall rules | Limited TCAM depth | Deep TCAM, hardware-rate ACLs |
| Jumbo frames (9216 MTU) | Usually supported | Yes (required for VXLAN overhead) |
| Telemetry | Basic SNMP/sFlow | WJH (What Just Happened) — per-packet drop/buffer visibility |
| Warm restart (hitless upgrade) | Rare | Supported — upgrade with zero traffic loss |

### Spectrum Switch Tiers

| Model Series | Ports | Typical Role |
|---|---|---|
| SN2000 | 48×25G + 8×100G | Leaf (small/medium) |
| SN3000 | 32×100G | Spine or high-density leaf |
| SN4000 | 64×100G or 32×400G | Spine (large fabrics) |
| SN5000 | 64×400G or 128×200G | Spine (hyperscale) |

---

## North-South Communication

North-south = traffic entering or leaving the datacenter (host ↔ internet/WAN).

### Flat Topology — North-South

```
H1 (10.0.0.11) wants to reach 8.8.8.8

1. H1 → default route → 10.0.0.1 (core router)
2. ARP: H1 resolves 10.0.0.1 MAC (L2, same subnet)
3. Core router: L3 lookup → NAT/route → internet

Path:  H1 → [L2 switch] → Core Router → Internet
Hops:  1 routed hop (everything before the router is L2 switching)
```

- Single exit point (core router)
- If the router goes down, all north-south traffic stops
- Bandwidth limited by single uplink to router

### Leaf/Spine — North-South

```
H1 (10.1.1.11) wants to reach 8.8.8.8

1. H1 → default route → Leaf1 (10.1.1.1, its ToR gateway)
2. Leaf1: BGP table says default route → Border Leaf, via Spine1 OR Spine2
3. Leaf1 picks best path (ECMP — load balances across both spines)
4. Spine1 → Border Leaf
5. Border Leaf: external BGP peer → Internet

Path:  H1 → Leaf1 → Spine → Border Leaf → Internet
Hops:  3 routed L3 hops
```

- **Redundant exit paths** — multiple border leaves possible
- **ECMP across spines** — all paths active simultaneously
- **No single point of failure** — lose a spine or border leaf, traffic reroutes
  in milliseconds (BFD)
- **Scales linearly** — add more border leaves for more external bandwidth

### North-South Comparison

| Aspect | Flat | Leaf/Spine |
|---|---|---|
| Default gateway | Single core router | Border leaf (can have multiple) |
| Redundancy | Active/standby (VRRP), STP blocks backup | ECMP — all paths active |
| Failover time | Seconds (STP reconvergence) | Milliseconds (BFD) |
| Bandwidth scaling | Limited by single uplink | Add border leaves / spines |
| Host config | Single default gateway IP | Single default gateway (leaf IP) |
| Complexity | Low | Medium — BGP config on all devices |

---

## East-West Communication

East-west = traffic between hosts within the datacenter (host ↔ host).

### Flat Topology — East-West

```
H1 (10.0.0.11) wants to reach H4 (10.0.0.14)

1. Same subnet → ARP: "who has 10.0.0.14?"
2. ARP broadcast hits ALL hosts on the segment
3. H4 replies with its MAC
4. H1 → L2 frame → switch forwards based on MAC table → H4

Path:  H1 → [L2 switch] → H4
Hops:  0 routed hops (pure L2 switching)
```

- Fast (L2 switching, no routing)
- But: ARP broadcasts scale poorly, no isolation between hosts, no multi-path

### Leaf/Spine — East-West (Same Rack)

```
H1 (10.1.1.11) wants to reach H2 (10.1.1.12) — both on Leaf1

1. Same subnet → ARP (contained to Leaf1's L2 domain only)
2. L2 switch within Leaf1 forwards directly

Path:  H1 → Leaf1 → H2
Hops:  0 routed hops (local L2)
```

### Leaf/Spine — East-West (Cross Rack)

```
H1 (10.1.1.11) wants to reach H4 (10.1.2.14) — different racks

1. Different subnet → H1 sends to Leaf1 (default gateway)
2. Leaf1: BGP table → 10.1.2.0/24 is behind Leaf2, via Spine1 or Spine2
3. ECMP: Leaf1 picks Spine1 (or Spine2, load-balanced per flow)
4. Spine1 → Leaf2
5. Leaf2 delivers to H4

Path:  H1 → Leaf1 → Spine → Leaf2 → H4
Hops:  3 routed L3 hops (always the same, predictable)
```

---

## VXLAN/EVPN Overlay — The DPU Story

This is where DPUs and Spectrum switches unlock multi-tenant isolation.

### The Problem

In a leaf/spine fabric, each rack is its own L2 domain. But tenants want:
- **L2 stretch** — VMs/containers in different racks behaving like they're on
  the same subnet
- **Isolation** — Tenant A's traffic can't see Tenant B's
- **Mobility** — workloads can move between racks without changing IPs

### The Solution: VXLAN + EVPN

**VXLAN** (Virtual Extensible LAN) creates L2 tunnels over the L3 fabric:

```
┌───────────────────────────────────────────────────┐
│               L3 Leaf/Spine Fabric                │
│                                                   │
│   ┌─────────┐    VXLAN tunnel    ┌─────────┐     │
│   │  VTEP   │═══════════════════ │  VTEP   │     │
│   │ (Leaf1) │  outer: L3 routed  │ (Leaf2) │     │
│   └────┬────┘  inner: L2 frame   └────┬────┘     │
│        │                               │          │
│     ┌──┴──┐                         ┌──┴──┐      │
│     │ H1  │  ← same virtual L2 →   │ H4  │      │
│     └─────┘    (VNI 10001)          └─────┘      │
└───────────────────────────────────────────────────┘

VTEP = VXLAN Tunnel Endpoint (encapsulates/decapsulates)
VNI  = VXLAN Network Identifier (like a VLAN ID, but 24-bit = 16M segments)
```

**EVPN** (Ethernet VPN) is the BGP-based control plane that tells VTEPs where
MAC/IP addresses live — which VTEP to tunnel to for a given destination:

- **Type-2 routes** — "MAC `aa:bb:cc` / IP `10.1.1.11` is behind VTEP
  `192.168.1.1`"
- **Type-5 routes** — "subnet `10.1.0.0/16` is reachable via VTEP
  `192.168.1.1` in VRF `tenant-a`"

### Where the DPU Fits In

With NICo, the **DPU is the VTEP** — not the leaf switch:

```
┌──────────────────────────────────────────────────────────┐
│                  L3 Leaf/Spine Fabric                     │
│              (carries underlay + VXLAN packets)           │
│                                                          │
│  Leaf1 ─── Spine ─── Leaf2                               │
│    │                    │                                 │
│  ┌─┴──────────┐     ┌──┴───────────┐                    │
│  │ DPU (VTEP) │═════│ DPU (VTEP)   │  VXLAN tunnel      │
│  │ VRF: vpc-a │     │ VRF: vpc-a   │  VNI: 10001        │
│  │ VRF: vpc-b │     │ VRF: vpc-b   │  VNI: 10002        │
│  ├────────────┤     ├──────────────┤                    │
│  │   Host 1   │     │   Host 2     │                    │
│  │ VM-a (vpc-a│)    │ VM-c (vpc-a) │  ← same VPC,       │
│  │ VM-b (vpc-b│)    │ VM-d (vpc-b) │    different racks  │
│  └────────────┘     └──────────────┘                    │
└──────────────────────────────────────────────────────────┘
```

The DPU handles:
- **VXLAN encap/decap** in hardware (line-rate, no host CPU cost)
- **Per-VPC VRF** — each tenant gets its own routing table
- **NSG enforcement** — ACL rules applied in the DPU data path
- **BGP/EVPN peering** — with the leaf (or route servers) for MAC/IP learning
- **ECMP** — multiple uplinks to the leaf, all active

The leaf switch just sees routed L3 packets (some of which happen to be
VXLAN-encapsulated). It doesn't need to know about tenants or VPCs.

### ETV vs FNN (NICo's Two Overlay Modes)

| Mode | Full Name | How it works |
|---|---|---|
| **ETV** | EVPN Type-V | L3 overlay — DPU creates per-VPC VRF, advertises EVPN Type-5 prefix routes. Each VPC is an isolated L3 domain |
| **FNN** | Flat No NAT | L3 overlay variant — similar to ETV but with different route-target and NAT behavior |

Both require a DPU as the VTEP and eBGP unnumbered on the leaf switch.

---

## How This Maps to NICo

| NICo Mode | Topology Required | North-South | East-West | Isolation |
|---|---|---|---|---|
| `dpu_policy = nic` (Flat VPC) | Any (flat or leaf/spine) | Operator-configured gateway | L2 switching or operator-configured routing | None from NICo — operator's responsibility |
| `dpu_policy = manage` (ETV) | Leaf/spine with eBGP | DPU → Leaf → Spine → Border Leaf | DPU VXLAN tunnel (Leaf → Spine → Leaf) | Per-VPC VRF + NSG on DPU (hardware-enforced) |
| `dpu_policy = manage` (FNN) | Leaf/spine with eBGP | Same as ETV | Same as ETV | Same as ETV (different RT/NAT behavior) |

### Decision Guide

```
Do you have DPUs (BlueField)?
├── No  → Flat VPC (any switch works, NICo = IPAM only)
├── Yes, but switch doesn't support eBGP unnumbered?
│   └── dpu_policy = nic → Flat VPC (DPU is just a NIC)
└── Yes, and switch supports eBGP unnumbered?
    └── dpu_policy = manage → ETV/FNN (full NICo networking)
        ├── Switch supports EVPN? → EVPN peering on leaf (simpler)
        └── Switch is L3 only?   → Route servers for EVPN overlay
```
