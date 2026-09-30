# NICo Integration Plan — Incremental Trust Build

This document defines the phased integration plan for NICo (NVIDIA Infra
Controller) on Red Hat OpenShift. Each phase adds a layer of complexity and
trust, validating one new dimension before moving to the next.

```
Phase 1          Phase 2            Phase 3              Phase 4
MAT              DPU + Host         Host-Only            Production
(Simulated)      (PXE Pairing)      (Full Lifecycle)     (Zero-Trust + eBGP)
─────────►       ─────────►         ─────────►           ─────────►
Software only    First real HW      Multi-host fleet     DPF, Vault PKI,
No network       L2 PXE network     Flat VPC tenancy     Leaf/spine EVPN
```

---

## Phase 1 — Machine-a-Tron (Simulated Environment)

### Description

Machine-a-Tron (MAT) is NICo's built-in bare-metal simulator. It runs entirely
inside the OpenShift cluster with **no physical hardware**. MAT spawns virtual
BMC endpoints via `bmc-mock` (a Redfish mock server), generates simulated DHCP
discoveries, and drives NICo's full state machine from discovery through to
`Ready`.

This phase proves the NICo control plane works end-to-end before any real
servers are involved. All security bypasses are enabled (RBAC bypass, no TPM
attestation, permissive auth) so failures are always infrastructure — never
policy.

**Deployed with:** `make deploy-site MAT=1`

**Key configuration (`nico-core-mat.yaml`):**

| Setting | Value | Why |
|---|---|---|
| `bypass_rbac` | `true` | Skip authorization checks |
| `attestation_enabled` | `false` | No TPM hardware |
| `allow_insecure_discovery` | `true` | Accept unverified BMCs |
| `allow_zero_dpu_hosts` | `true` | NoDpu mode |
| `host_count` | `2` | Two simulated hosts |
| `dpu_per_host_count` | `0` | No DPU simulation |
| `bmc-mock port` | `1266` | Single shared mock BMC |

**Emulator networks:**

| Network | CIDR | Type | MTU |
|---|---|---|---|
| OOB | `192.168.2.0/24` | underlay | 1500 |
| Admin | `192.168.252.0/24` | admin | 9000 |
| HostInband | `192.168.253.0/24` | hostinband | 9000 |

### What We Are Verifying

- NICo Core services start and pass health checks (nico-api, nico-dhcp, nico-dns, nico-pxe, nico-bmc-proxy)
- Infrastructure layer works: Crunchy PG, Vault HA, NATS, ESO
- Vault PKI issues certificates via `vault-nico-issuer`
- DHCP hook library loads and processes discoveries
- BMC discovery via Redfish succeeds (bmc-mock)
- Full state machine: `HostDiscovered → HostInitializing → SetBootOrder → WaitingForLockdown → BomValidating → Ready`
- Database migrations run cleanly (nico-api-migrate job)
- NoDpu hosts can be allocated to a tenant (flat VPC, HostInband segment)

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                   OpenShift Cluster                         │
│                                                             │
│  ┌────────────────── nico-system namespace ───────────────┐ │
│  │                                                        │ │
│  │  ┌──────────────────────────────────────────────────┐  │ │
│  │  │              NICo Core Services                  │  │ │
│  │  │                                                  │  │ │
│  │  │  ┌──────────┐ ┌──────────┐ ┌──────────────────┐ │  │ │
│  │  │  │ nico-api │ │nico-dhcp │ │ nico-bmc-proxy   │ │  │ │
│  │  │  │ (gRPC    │ │ (Kea +   │ │ (Redfish proxy)  │ │  │ │
│  │  │  │  :1079)  │ │  hooks)  │ │                  │ │  │ │
│  │  │  └────┬─────┘ └─────┬────┘ └───────┬──────────┘ │  │ │
│  │  │       │              │              │            │  │ │
│  │  │  ┌────┴─────┐ ┌─────┴────┐ ┌───────┴──────────┐ │  │ │
│  │  │  │ nico-dns │ │ nico-pxe │ │ nico-hw-health   │ │  │ │
│  │  │  │ (:5353)  │ │ (:8080)  │ │                  │ │  │ │
│  │  │  └──────────┘ └──────────┘ └──────────────────┘ │  │ │
│  │  └──────────────────────┬───────────────────────────┘  │ │
│  │                         │                              │ │
│  │                         ▼                              │ │
│  │  ┌──────────────────────────────────────────────────┐  │ │
│  │  │            Machine-a-Tron (MAT)                  │  │ │
│  │  │                                                  │  │ │
│  │  │   bmc-mock (:1266)      Simulated DHCP           │  │ │
│  │  │   ┌──────────────┐      Discoveries              │  │ │
│  │  │   │  Redfish API │◄─────────────────────────     │  │ │
│  │  │   │  (2 virtual  │      ┌──────────────────┐     │  │ │
│  │  │   │   hosts)     │      │ Emulator Networks│     │  │ │
│  │  │   └──────────────┘      │ OOB  192.168.2/24│     │  │ │
│  │  │                         │ Admin 192.168.252 │     │  │ │
│  │  │                         │ Inband 192.168.253│     │  │ │
│  │  │                         └──────────────────┘     │  │ │
│  │  └──────────────────────────────────────────────────┘  │ │
│  │                                                        │ │
│  │  ┌───────────┐  ┌──────────┐  ┌────────────────────┐  │ │
│  │  │ Vault HA  │  │  NATS    │  │ nico-site-pg (PG15)│  │ │
│  │  │ (3-node   │  │ (MQTT)   │  │ DBs: nico, flow,   │  │ │
│  │  │  Raft)    │  │          │  │      psm, nsm      │  │ │
│  │  └───────────┘  └──────────┘  └────────────────────┘  │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                             │
│  ┌──── cert-manager ────┐  ┌──── ESO ────┐                 │
│  │ nico-root-ca         │  │ Secret sync  │                 │
│  │ vault-nico-issuer    │  │ (CA certs)   │                 │
│  └──────────────────────┘  └─────────────┘                  │
└─────────────────────────────────────────────────────────────┘

         No physical network. No real hardware.
         Everything is simulated inside the cluster.
```

### Network Diagram

```
                    ┌─────────────────────────────┐
                    │     In-Cluster (Virtual)     │
                    │                              │
  ┌─────────┐      │  ┌─────────┐  ┌──────────┐  │
  │ nico-api├──────┼─►│nico-dhcp│  │ nico-dns │  │
  └─────────┘      │  └────┬────┘  └────┬─────┘  │
                    │       │            │         │
                    │       ▼            ▼         │
                    │  ┌──────────────────────┐    │
                    │  │  Emulator Network    │    │
                    │  │  (Pod-internal)      │    │
                    │  │                      │    │
                    │  │  OOB: 192.168.2.0/24 │    │
                    │  │  ┌──────┐ ┌──────┐   │    │
                    │  │  │Host 1│ │Host 2│   │    │
                    │  │  │(mock)│ │(mock)│   │    │
                    │  │  └──┬───┘ └──┬───┘   │    │
                    │  │     │        │       │    │
                    │  │     ▼        ▼       │    │
                    │  │  ┌──────────────┐    │    │
                    │  │  │  bmc-mock    │    │    │
                    │  │  │  (Redfish)   │    │    │
                    │  │  │  :1266       │    │    │
                    │  │  └──────────────┘    │    │
                    │  └──────────────────────┘    │
                    └─────────────────────────────┘

  No DHCP relay. No physical switches. No real BMCs.
  All traffic is pod-to-pod within the cluster.
```

---

## Lab Network Setup (Shared — Phases 2 & 3)

Phases 2 and 3 use the **same physical lab network**. Set it up once, then
transition between phases with NICo config changes only — no re-cabling,
no VLAN changes, no switch reconfiguration.

### Why It Works

Both phases need the same three things from the network:

1. **MetalLB VIP** — exposes DHCP/DNS/PXE to the physical network
2. **L2 data plane segment** — carries PXE boot traffic (DHCP discover, boot
   image download) from server NICs / DPU data plane ports to the VIP
3. **OOB management network** — carries Redfish traffic from bmc-proxy to all
   BMCs (DPU and host)

The DPU's data plane ports (eth0/eth1) and standalone hosts' NICs connect to
the **same L2 segment on the same ToR switch**. In Phase 2 the DPU uses that
segment; in Phase 3 the hosts use it directly. Both are just Ethernet ports
sending DHCP discovers to the same VIP.

### One-Time Setup

**Deploy command (both phases):** `make deploy-site SITE_VIP=<lab-vip>`

**Required infrastructure:**

| Component | Setup | Notes |
|---|---|---|
| MetalLB | Install operator, create IPAddressPool for VIP | One-time |
| ToR switch | One VLAN/L2 segment for data plane | Trunk to OpenShift + access for servers |
| OOB switch | Management network for BMCs | May be same or separate switch |
| DHCP subnet | Configure real subnet in `nico-core.yaml` | Replace `0.0.0.0/0` placeholder |
| Boot artifacts | Populate PXE containers | BFB image (Phase 2), scout.efi (both) |

**Required network paths (superset — covers both phases):**

| From | To | Protocol | Port | Phase |
|---|---|---|---|---|
| DPU data plane (eth0/eth1) | NICo DHCP | UDP | 67/68 | 2 |
| Host NIC | NICo DHCP | UDP | 67/68 | 2 (via bridge), 3 (direct) |
| DPU / Host NIC | NICo PXE | TCP | 8080 | 2, 3 |
| DPU / Host NIC | NICo DNS | UDP/TCP | 53 | 2, 3 |
| NICo bmc-proxy | DPU BMC | TCP | 443 (Redfish) | 2 |
| NICo bmc-proxy | Host BMC(s) | TCP | 443 (Redfish) | 2, 3 |

**Lab hardware:**

| Component | Details |
|---|---|
| DPU | BlueField-3, BMC `10.6.136.28`, firmware BF-26.04-8 |
| Host (DPU server) | Dell PowerEdge R750, BMC `10.6.136.44` |
| DPU eth0 | `02:de:1f:c2:c5:11` (100 Gbps, data plane) |
| DPU eth1 | `02:31:dd:95:f6:18` (100 Gbps, data plane) |
| DPU oob0 | `a0:88:c2:75:91:8e` (1 Gbps, management) |
| DPU BMC MAC | `a0:88:c2:75:91:8f` (used for registration) |
| Additional hosts | Any Redfish-capable servers (Phase 3) |

### Network Diagram (Shared)

```
                          OpenShift Cluster
                        ┌──────────────────┐
                        │  NICo Site       │
                        │  (nico-system)   │
                        │                  │
                        │  DHCP ─┐         │
                        │  DNS  ─┼─ MetalLB│
                        │  PXE  ─┘   VIP   │
                        │         10.6.141.x│
                        │                  │
                        │  bmc-proxy ──┐   │
                        └──────────┬───┼───┘
                                   │   │
             ┌─────────────────────┤   │
             │                     │   │
             │    Data Plane L2    │   │   OOB Network
             │    (shared segment) │   │   (BMC Redfish)
             │                     │   │
  ┌──────────┴─────────────────────┴───┴──────────────────┐
  │                    ToR Switch                          │
  │                                                        │
  │  VLAN/L2 segment: data plane          OOB ports        │
  └──┬────────┬────────┬────────┬─────────┬───────┬───────┘
     │        │        │        │         │       │
     │ Phase 2│        │        │ Phase 3 │       │
     │        │        │        │         │       │
  ┌──┴──┐  ┌─┴──┐  ┌──┴──┐  ┌─┴──┐   ┌──┴──┐ ┌──┴──┐
  │DPU  │  │DPU │  │Host │  │Host│   │All  │ │All  │
  │eth0 │  │eth1│  │NIC  │  │NIC │   │Host │ │DPU  │
  │100G │  │100G│  │(R750│  │(+N)│   │BMCs │ │BMCs │
  │     │  │    │  │via  │  │    │   │iDRAC│ │     │
  │     │  │    │  │DPU  │  │    │   │     │ │     │
  │     │  │    │  │brdg)│  │    │   │     │ │     │
  └──┬──┘  └─┬──┘  └──┬──┘  └─┬──┘   └─────┘ └─────┘
     │       │        │       │
     └───┬───┘        └───┬───┘
         │                │
   BlueField-3       Standalone
   DPU + Host        Hosts
   (Phase 2)         (Phase 3)

   Same switch ports. Same VLAN. Same VIP.
```

### Transitioning Between Phases

| Step | What Changes | How |
|---|---|---|
| Phase 2 → 3 | Register standalone hosts (no DPU) | REST API: `expected-machines` with host-only entries |
| Phase 2 → 3 | Enable NoDpu mode | Set `allow_zero_dpu_hosts: true` in values |
| Phase 2 → 3 | Seed host BMC creds | Vault: `machines/bmc/<MAC>/root` for each new host |
| Phase 2 → 3 | Boot artifacts | Ensure host OS image is in PXE server (not just BFB) |
| Phase 2 → 3 | Networking mode | Set `dpu_policy: nic` (flat VPC) |

No network changes. No switch changes. No MetalLB changes.

---

## Phase 2 — DPU and Host Pairing (PXE Boot)

> **Lab network:** Uses the shared setup above. No additional network config.

### Description

First contact with real hardware. A BlueField-3 DPU and its host server (Dell
PowerEdge R750) are connected to the lab network. The DPU boots via UEFI HTTP
Boot over its data plane ports, downloading a BFB (BlueField Boot) image from
NICo's PXE server. The host then PXE boots through the DPU's bridge interface.

**Deployed with:** `make deploy-site SITE_VIP=<lab-vip>`

### What We Are Verifying

- MetalLB assigns SITE_VIP and exposes DHCP/DNS/PXE externally
- L2 data plane segment carries DPU DHCP discovers to NICo
- DHCP hook processes real DPU MAC discovery and assigns IP
- BMC credentials seeded in Vault (`machines/bmc/<MAC>/root`)
- Redfish probe reads real DPU/Host BMC inventory (NIC MACs, firmware, serial)
- DPU registration via REST API (`expected-machines`)
- DPU UEFI HTTP Boot triggers: DPU fetches BFB image from PXE server
- Host PXE boot through DPU bridge: host fetches `scout.efi`
- DPU reaches `DpuReady` state
- Host reaches `HostInitializing` state (pairing confirmed)
- Kea DHCP can bind privileged port 67 (NET_BIND_SERVICE capability)
- Boot artifact containers are populated (BFB image, scout.efi)

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                       OpenShift Cluster                         │
│                                                                 │
│  ┌─────────────────── nico-system ────────────────────────────┐ │
│  │                                                            │ │
│  │  ┌────────┐ ┌────────┐ ┌────────┐ ┌──────────────────┐    │ │
│  │  │nico-api│ │  dhcp  │ │  dns   │ │    nico-pxe      │    │ │
│  │  │ :1079  │ │ :67/68 │ │ :53    │ │ :8080            │    │ │
│  │  └───┬────┘ └───┬────┘ └───┬────┘ │ BFB + scout.efi  │    │ │
│  │      │          │          │      └───────┬──────────┘    │ │
│  │      │          │          │              │               │ │
│  │  ┌───┴──────────┴──────────┴──────────────┴────────────┐  │ │
│  │  │              MetalLB LoadBalancer                    │  │ │
│  │  │              SITE_VIP = 10.6.141.x                  │  │ │
│  │  │              (shared-IP annotation)                  │  │ │
│  │  └──────────────────────┬──────────────────────────────┘  │ │
│  │                         │                                 │ │
│  │  ┌──────────┐ ┌────────┴───┐ ┌────────────────────────┐  │ │
│  │  │ Vault HA │ │ bmc-proxy  │ │ nico-site-pg (PG15)    │  │ │
│  │  │ (PKI +   │ │ (Redfish   │ │ DBs: nico, flow        │  │ │
│  │  │  AppRole)│ │  proxy)    │ │                        │  │ │
│  │  └──────────┘ └──────┬─────┘ └────────────────────────┘  │ │
│  └───────────────────────┼───────────────────────────────────┘ │
│                          │                                     │
└──────────────────────────┼─────────────────────────────────────┘
                           │
          ─────────────────┼──────────────────────
          Physical Network │ (same L2 segment)
          ─────────────────┼──────────────────────
                           │
          ┌────────────────┼────────────────────┐
          │                │                    │
          ▼                ▼                    ▼
  ┌──────────────┐ ┌──────────────┐   ┌──────────────┐
  │  DPU BMC     │ │  Host BMC    │   │    ToR       │
  │ 10.6.136.28  │ │ 10.6.136.44  │   │   Switch     │
  │ (Redfish)    │ │ (Redfish)    │   │              │
  └──────┬───────┘ └──────┬───────┘   └──────┬───────┘
         │                │                  │
  ┌──────┴────────────────┴──────────────────┴───────┐
  │              Dell PowerEdge R750                  │
  │                                                   │
  │  ┌─────────────────────────────────────────────┐  │
  │  │            BlueField-3 DPU                  │  │
  │  │                                             │  │
  │  │  eth0 (100G)──┐    oob0 (1G)               │  │
  │  │  eth1 (100G)──┤    Management               │  │
  │  │               │                             │  │
  │  │        Data Plane Ports                     │  │
  │  │        (PXE boot source)                    │  │
  │  │               │                             │  │
  │  │               ▼                             │  │
  │  │    ┌───────────────────┐                    │  │
  │  │    │  DPU Bridge       │                    │  │
  │  │    │  (passes host PXE │                    │  │
  │  │    │   traffic through)│                    │  │
  │  │    └───────────────────┘                    │  │
  │  └─────────────────────────────────────────────┘  │
  │                                                   │
  │  Host x86_64 (boots via DPU bridge)               │
  └───────────────────────────────────────────────────┘
```

### Boot Sequence Diagram

```
  DPU eth0/eth1                    MetalLB VIP
  (on shared L2)                   (DHCP/DNS/PXE)
       │                                │
       │  1. DHCP Discover (DPU MAC)    │
       ├───────────────────────────────►│
       │  2. DHCP Offer (IP)            │
       │◄───────────────────────────────┤
       │  3. HTTP GET /bfb (BFB image)  │
       ├───────────────────────────────►│
       │  4. DPU boots, enables bridge  │
       │                                │
  Host (via DPU bridge)                 │
       │  5. DHCP Discover (Host MAC)   │
       ├───────────────────────────────►│
       │  6. DHCP Offer (IP)            │
       │◄───────────────────────────────┤
       │  7. HTTP GET /scout.efi        │
       ├───────────────────────────────►│
       │  8. Host boots scout agent     │
       │                                │
```

---

## Phase 3 — Fully Integrated Host-Only Mode

> **Lab network:** Uses the same shared setup as Phase 2. Only NICo config
> changes — no network or switch modifications.

### Description

Multiple bare-metal hosts (no DPUs) go through the complete NICo lifecycle:
network boot, discovery, provisioning, and allocation to a tenant. This proves
the full operational workflow — from powered-off server to running tenant
workload — using flat VPC networking (`dpu_policy=nic`).

Hosts PXE boot **directly from their own NICs** on the same L2 segment that
the DPU used in Phase 2. NICo acts as the IPAM and lifecycle controller —
DHCP assigns IPs, DNS resolves hostnames, PXE serves the boot image, and the
BMC proxy manages power and boot order via Redfish.

**Deployed with:** `make deploy-site SITE_VIP=<lab-vip>` (same VIP as Phase 2)

**Config changes from Phase 2:**

| Setting | Phase 2 | Phase 3 |
|---|---|---|
| `allow_zero_dpu_hosts` | `false` | `true` |
| `dpu_policy` | (DPU pairing) | `nic` (flat VPC) |
| Expected machines | DPU + Host pair | Host-only entries |
| Boot artifacts | BFB + scout.efi | Host OS image |
| Vault BMC seeds | DPU + Host BMCs | Host BMCs only |

### What We Are Verifying

- End-to-end lifecycle for real bare-metal hosts (no simulation, no DPU)
- DHCP discovery with real MAC addresses on the same physical network
- BMC auto-discovery via Redfish (real vendor firmware — Dell iDRAC, etc.)
- PXE boot: host powers on → DHCP → HTTP → OS image (direct from NIC, not via DPU bridge)
- Host state machine completes: `Discovered → Initializing → SetBootOrder → WaitingForLockdown → BomValidating → Ready`
- Tenant creation and host allocation (`/v2/org/<org>/nico/tenant/`)
- VPC creation on HostInband segment (flat VPC, no overlay)
- Multi-host fleet management (>2 hosts)
- BMC credential lifecycle in Vault (seed → rotate)
- Site-agent registers with cloud Temporal and reports state
- Cloud ↔ Site connectivity: REST API (cloud) sees site-managed hosts
- NTP synchronization across fleet

### Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────────┐
│                        OpenShift Cluster                             │
│                                                                      │
│  ┌────── nico-rest (Cloud) ──────┐  ┌──── nico-system (Site) ─────┐ │
│  │                               │  │                              │ │
│  │  ┌─────────┐ ┌─────────────┐  │  │ ┌────────┐ ┌─────────────┐ │ │
│  │  │nico-rest│ │  Temporal    │  │  │ │nico-api│ │  site-agent │ │ │
│  │  │  API    │ │  Server     │◄─┼──┼─┤        │ │  (Temporal  │ │ │
│  │  └────┬────┘ └─────────────┘  │  │ │ :1079  │ │   client)   │ │ │
│  │       │                       │  │ └───┬────┘ └─────────────┘ │ │
│  │  ┌────┴────┐ ┌─────────────┐  │  │     │                      │ │
│  │  │cloud-   │ │  Keycloak   │  │  │ ┌───┴────┐ ┌────────────┐ │ │
│  │  │worker   │ │  (RHBK)     │  │  │ │  dhcp  │ │ bmc-proxy  │ │ │
│  │  │site-    │ │  (nico      │  │  │ │ :67/68 │ │ (Redfish)  │ │ │
│  │  │worker   │ │   realm)    │  │  │ └───┬────┘ └─────┬──────┘ │ │
│  │  └─────────┘ └─────────────┘  │  │     │            │        │ │
│  │                               │  │ ┌───┴────┐ ┌─────┴──────┐ │ │
│  │  ┌─────────────────────────┐  │  │ │  dns   │ │  nico-pxe  │ │ │
│  │  │ nico-cloud-pg (PG18)   │  │  │ │  :53   │ │  :8080     │ │ │
│  │  │ DBs: nico, temporal,   │  │  │ └────────┘ └────────────┘ │ │
│  │  │       keycloak         │  │  │                            │ │
│  │  └─────────────────────────┘  │  │ ┌────────┐ ┌────────────┐│ │
│  └───────────────────────────────┘  │ │Vault HA│ │nico-site-pg││ │
│                                      │ │(3-node)│ │  (PG15)    ││ │
│                                      │ └────────┘ └────────────┘│ │
│                                      │                           │ │
│                                      │ ┌─────────────────────┐   │ │
│                                      │ │   MetalLB VIP       │   │ │
│                                      │ │   (same as Phase 2) │   │ │
│                                      │ └──────────┬──────────┘   │ │
│                                      └─────────────┼─────────────┘ │
└────────────────────────────────────────────────────┼────────────────┘
                                                     │
                    ─────────────────────────────────┼──────────
                    Same Physical Network (same L2)  │
                    ─────────────────────────────────┼──────────
                                                     │
            ┌────────────────────────────────────────┤
            │                │                       │
     ┌──────┴──────┐  ┌─────┴───────┐  ┌────────────┴────────────┐
     │   Host 1    │  │   Host 2    │  │   Host N                │
     │             │  │             │  │                          │
     │ BMC(iDRAC)  │  │ BMC(iDRAC)  │  │ BMC(Redfish)            │
     │ NIC (1G/25G)│  │ NIC (1G/25G)│  │ NIC (1G/25G)            │
     │             │  │             │  │                          │
     │ PXE Boot ───┼──┼─────────────┼──┼──► DHCP → PXE → OS     │
     │ (direct,    │  │             │  │    (same VIP as Ph.2)   │
     │  no DPU)    │  │             │  │                          │
     │ ┌─────────┐ │  │ ┌─────────┐ │  │ ┌─────────┐             │
     │ │ Tenant  │ │  │ │ Tenant  │ │  │ │ Tenant  │             │
     │ │Workload │ │  │ │Workload │ │  │ │Workload │             │
     │ └─────────┘ │  │ └─────────┘ │  │ └─────────┘             │
     └─────────────┘  └─────────────┘  └──────────────────────────┘

     Flat VPC (dpu_policy=nic): NICo = IPAM, operator manages switches
```

### Boot Sequence Diagram

```
  Host NIC                         MetalLB VIP
  (on same L2 as Phase 2)         (same DHCP/DNS/PXE)
       │                                │
       │  1. DHCP Discover (Host MAC)   │
       ├───────────────────────────────►│
       │  2. DHCP Offer (IP)            │
       │◄───────────────────────────────┤
       │  3. HTTP GET /os-image         │
       ├───────────────────────────────►│
       │  4. Host boots OS              │
       │  5. Scout agent starts         │
       │  6. BMC probed via Redfish     │
       │  7. Host → Ready               │
       │                                │
       │  No DPU in the path.           │
       │  Direct NIC-to-VIP on same L2. │
```

---

## Phase 4 — Production Setup (Zero-Trust, DPF, eBGP)

### Description

Full production architecture with zero-trust security, DPU-managed networking,
and eBGP leaf/spine fabric. The Data Processing Framework (DPF) manages DPU
lifecycle. Each DPU acts as a hardware VTEP, performing VXLAN encap/decap at
line rate with per-VPC VRF isolation and NSG enforcement in the data path.

NICo operates in `dpu_policy=manage` mode (ETV or FNN), where it programs the
DPU's networking stack and peers with leaf switches via eBGP unnumbered
(RFC 5549). Vault PKI provides SPIFFE-based identity for all services. No
security bypasses — full attestation, RBAC, and mutual TLS throughout.

**Deployed with:** `make deploy-all-cloud` + `make deploy-all-site SITE_VIP=<vip>`

**Networking mode:** ETV or FNN (`dpu_policy=manage`) — DPU is VTEP, eBGP
unnumbered peering with ToR, EVPN Type-5 routes, per-VPC VRF.

**Security posture:**

| Setting | Value |
|---|---|
| `bypass_rbac` | `false` |
| `attestation_enabled` | `true` |
| `tpm_required` | `true` |
| `allow_insecure_discovery` | `false` |
| `permissive_mode` | `false` |
| Vault unseal | Cloud KMS (AWS/GCP/Azure) or external Transit |
| Identity | SPIFFE (`spiffe://nico.local/...`) via Vault PKI |
| mTLS | All service-to-service via `vault-nico-issuer` certs |

**IP/VNI pools (from site config):**

| Pool | Range | Purpose |
|---|---|---|
| lo-ip | `10.100.0.1` – `10.100.0.254` | DPU loopback IPs |
| vpc-dpu-lo | `10.101.0.1` – `10.101.0.254` | VPC DPU loopback |
| secondary-vtep-ip | `10.102.0.1` – `10.102.0.254` | Secondary VTEP |
| VNI | `100000` – `199999` | Infra VNIs |
| vpc-vni | `200000` – `299999` | Tenant VPC VNIs |
| external-vpc-vni | `300000` – `399999` | External VPC VNIs |
| VLAN | `100` – `4094` | VLAN pool |
| fnn-asn | `4200000000` – `4200000254` | DPU BGP ASNs |

### What We Are Verifying

- Zero-trust security: mTLS everywhere, Vault PKI with SPIFFE identities
- TPM attestation on host discovery (no `allow_insecure_discovery`)
- RBAC enforcement on all API calls (Keycloak tokens, role-based access)
- DPF manages DPU lifecycle (firmware, OS, networking config)
- DPU as hardware VTEP: VXLAN encap/decap at line rate
- eBGP unnumbered peering between DPU and ToR leaf switch
- EVPN Type-5 route advertisement for VPC subnets
- Per-VPC VRF isolation on DPU (tenant traffic separation)
- NSG enforcement in DPU data path (ACL rules)
- ECMP across multiple DPU uplinks and spine paths
- BFD sub-second failure detection
- Vault KMS-based unseal (no K8s Secret for unseal keys)
- Multi-site: cloud Temporal orchestrates multiple sites
- Full Keycloak auth flow: `ncx-service` (M2M) + human user tokens
- Tenant lifecycle: create org → create tenant → allocate hosts → create VPC → workloads

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     NICo Cloud (nico-rest namespace)                    │
│                                                                         │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────┐ │
│  │ REST API │ │ cloud-   │ │ site-    │ │ site-    │ │   Temporal   │ │
│  │          │ │ worker   │ │ worker   │ │ manager  │ │   Server     │ │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘ └──────┬───────┘ │
│  ┌──────────┐ ┌────────────────────┐ ┌───────────────────┐  │         │
│  │ Keycloak │ │ nico-cloud-pg PG18 │ │  OpenShift Routes │  │         │
│  │ (RHBK)   │ │ (nico,temporal,kc) │ │  (reencrypt TLS)  │  │         │
│  └──────────┘ └────────────────────┘ └───────────────────┘  │         │
└─────────────────────────────────────────────────────────────┼─────────┘
                                                              │
                            Temporal gRPC (mTLS)              │
                                                              │
┌─────────────────────────────────────────────────────────────┼─────────┐
│                     NICo Site (nico-system namespace)        │         │
│                                                              │         │
│  ┌────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌───────┴──────┐ │
│  │nico-api│ │   dhcp   │ │   dns    │ │   pxe    │ │  site-agent  │ │
│  │ :1079  │ │  :67/68  │ │   :53    │ │  :8080   │ │              │ │
│  └───┬────┘ └──────────┘ └──────────┘ └──────────┘ └──────────────┘ │
│      │                                                               │
│  ┌───┴──────────┐ ┌──────────┐ ┌──────────┐ ┌────────────────────┐  │
│  │  bmc-proxy   │ │ nico-flow│ │ ssh-     │ │ hw-health          │  │
│  │  (Redfish)   │ │ (PSM/NSM)│ │ console  │ │                    │  │
│  └──────────────┘ └──────────┘ └──────────┘ └────────────────────┘  │
│                                                                      │
│  ┌──────────┐  ┌──────────┐  ┌────────────────┐  ┌──────────────┐   │
│  │ Vault HA │  │   NATS   │  │ nico-site-pg   │  │   MetalLB    │   │
│  │ 3-node   │  │  (MQTT)  │  │   (PG15)       │  │    VIP       │   │
│  │ KMS seal │  │          │  │                │  │              │   │
│  └──────────┘  └──────────┘  └────────────────┘  └──────┬───────┘   │
└──────────────────────────────────────────────────────────┼───────────┘
                                                           │
═══════════════════════════════════════════════════════════╪═══════════
                      Production Network                   │
═══════════════════════════════════════════════════════════╪═══════════
                                                           │
┌──────────────────────────────────────────────────────────┼──────────┐
│                      Leaf/Spine Fabric                    │          │
│                                                          │          │
│                    ┌──────────┐ ┌──────────┐             │          │
│                    │ Spine  1 │ │ Spine  2 │   eBGP      │          │
│                    └────┬─┬──┘ └──┬─┬─────┘   peering   │          │
│                    ECMP │ │      │ │  ECMP               │          │
│              ┌─────────┘ └──┐┌──┘ └─────────┐            │          │
│              │              ││              │            │          │
│         ┌────┴─────┐  ┌────┴┴─────┐  ┌─────┴────┐       │          │
│         │ Leaf / ToR│  │ Leaf / ToR│  │ Leaf / ToR│       │          │
│         │ Switch 1  │  │ Switch 2  │  │ Switch N  │       │          │
│         └──┬────┬───┘  └──┬────┬───┘  └──┬────┬───┘       │          │
│  eBGP      │    │         │    │         │    │            │          │
│  unnumbered│    │         │    │         │    │            │          │
│  (RFC 5549)│    │         │    │         │    │            │          │
│            ▼    ▼         ▼    ▼         ▼    ▼            │          │
│  ┌─────────────────┐ ┌─────────────────┐ ┌────────────┐   │          │
│  │   Server Rack 1 │ │   Server Rack 2 │ │  Rack N    │   │          │
│  │                  │ │                  │ │            │   │          │
│  │  ┌────────────┐  │ │  ┌────────────┐  │ │  ┌──────┐ │   │          │
│  │  │   DPU      │  │ │  │   DPU      │  │ │  │ DPU  │ │   │          │
│  │  │ (BF-3)     │  │ │  │ (BF-3)     │  │ │  │      │ │   │          │
│  │  │ ┌────────┐ │  │ │  │ ┌────────┐ │  │ │  │      │ │   │          │
│  │  │ │VTEP    │ │  │ │  │ │VTEP    │ │  │ │  │      │ │   │          │
│  │  │ │VXLAN   │ │  │ │  │ │VXLAN   │ │  │ │  │      │ │   │          │
│  │  │ │VRF/VPC │ │  │ │  │ │VRF/VPC │ │  │ │  │      │ │   │          │
│  │  │ │NSG/ACL │ │  │ │  │ │NSG/ACL │ │  │ │  │      │ │   │          │
│  │  │ └────────┘ │  │ │  │ └────────┘ │  │ │  │      │ │   │          │
│  │  └─────┬──────┘  │ │  └─────┬──────┘  │ │  └──┬───┘ │   │          │
│  │        │         │ │        │         │ │     │     │   │          │
│  │  ┌─────┴──────┐  │ │  ┌─────┴──────┐  │ │  ┌──┴───┐ │   │          │
│  │  │  Host      │  │ │  │  Host      │  │ │  │ Host │ │   │          │
│  │  │  (x86_64)  │  │ │  │  (x86_64)  │  │ │  │      │ │   │          │
│  │  │  TPM 2.0   │  │ │  │  TPM 2.0   │  │ │  │      │ │   │          │
│  │  └────────────┘  │ │  └────────────┘  │ │  └──────┘ │   │          │
│  └──────────────────┘ └──────────────────┘ └───────────┘   │          │
└────────────────────────────────────────────────────────────┘          │
```

### Network Diagram

```
                NICo Site (OpenShift)
                ┌─────────────────┐
                │ DHCP/DNS/PXE    │── MetalLB VIP
                │ nico-flow       │   (external)
                │  ├── PSM        │
                │  └── NSM        │
                │ bmc-proxy       │── OOB Network
                └────────┬────────┘        │
                         │                 │
  ═══════════════════════╪═════════════════╪══════════════
  OOB Management Network │                 │
  (BMC Redfish, IPMI)    │                 │
  ═══════════════════════╪═════════════════╪══════════════
                         │                 │
                    ┌────┴────┐      ┌─────┴─────┐
                    │Host BMCs│      │ DPU BMCs   │
                    └─────────┘      └────────────┘


  ═══════════════════════════════════════════════════════
  Data Plane Fabric (eBGP Unnumbered / EVPN / VXLAN)
  ═══════════════════════════════════════════════════════
                    │                   │
            ┌───────┴───────┐   ┌───────┴───────┐
            │   Spine 1     │   │   Spine 2     │
            │  ASN 6500x    │   │  ASN 6500x    │
            └───┬───┬───┬───┘   └───┬───┬───┬───┘
           ECMP │   │   │          │   │   │ ECMP
            ┌───┘   │   └──┐  ┌───┘   │   └──┐
            │       │      │  │       │      │
        ┌───┴──┐ ┌──┴───┐ ┌┴──┴──┐   │      │
        │Leaf 1│ │Leaf 2│ │Leaf 3│   ...    ...
        │ToR   │ │ToR   │ │ToR   │
        └──┬───┘ └──┬───┘ └──┬───┘
  eBGP     │        │        │     eBGP
  unnumbrd │        │        │     unnumbrd
  (v6 LL)  │        │        │     (v6 LL)
           │        │        │
     ┌─────┴──┐ ┌───┴────┐ ┌┴───────┐
     │ DPU 1  │ │ DPU 2  │ │ DPU N  │
     │ BF-3   │ │ BF-3   │ │ BF-3   │
     │        │ │        │ │        │
     │ ASN    │ │ ASN    │ │ ASN    │
     │ 42000..│ │ 42000..│ │ 42000..│
     │        │ │        │ │        │
     │ VTEP ──┼─┼── VXLAN tunnel ──┼── VNI 200000-299999
     │ VRF  ──┼─┼── per-VPC ───────┼── tenant isolation
     │ NSG  ──┼─┼── ACL rules ─────┼── security groups
     │        │ │        │ │        │
     │ eth0 ◄─┤ │ eth0 ◄─┤ │ eth0 ◄─┤  100G uplinks
     │ eth1 ◄─┤ │ eth1 ◄─┤ │ eth1 ◄─┤  to leaf switch
     └───┬────┘ └───┬────┘ └───┬────┘
         │          │          │
     ┌───┴────┐ ┌───┴────┐ ┌──┴─────┐
     │ Host 1 │ │ Host 2 │ │ Host N │
     │ TPM2.0 │ │ TPM2.0 │ │ TPM2.0 │
     │        │ │        │ │        │
     │Tenant A│ │Tenant A│ │Tenant B│  ◄── VPC isolation
     │VPC 1   │ │VPC 1   │ │VPC 2   │      via DPU VRF
     └────────┘ └────────┘ └────────┘

  Traffic flow (Tenant A, Host 1 → Host 2):
  ┌──────────────────────────────────────────────────┐
  │ App → DPU1 VRF → VXLAN encap → Leaf1 → Spine    │
  │   → Leaf2 → VXLAN decap → DPU2 VRF → App        │
  │                                                   │
  │ All at line rate. NSG enforced at DPU ingress.   │
  └──────────────────────────────────────────────────┘
```

---

## Phase Summary

| | Phase 1 | Phase 2 | Phase 3 | Phase 4 |
|---|---|---|---|---|
| **Hardware** | None (simulated) | 1 DPU + 1 Host | Multiple hosts | DPU + Host fleet |
| **Lab Network** | In-cluster only | Shared L2 + OOB | **Same as Phase 2** | eBGP leaf/spine (new) |
| **Network Change** | N/A | Set up once | None | New fabric required |
| **DPU Mode** | NoDpu | DPU pairing | `dpu_policy=nic` | `dpu_policy=manage` |
| **PXE Path** | Simulated | DPU data plane → bridge | Host NIC direct | DPU data plane |
| **Security** | All bypassed | Partial (Vault creds) | Vault + Keycloak | Zero-trust (mTLS, TPM, RBAC) |
| **Tenant Ops** | Allocate (mock) | Not yet | Full lifecycle | Full + VPC overlay |
| **Switch Config** | N/A | One-time setup | **No change** | NICo-managed (EVPN) |
| **Make Target** | `deploy-site MAT=1` | `deploy-site SITE_VIP=x` | `deploy-site SITE_VIP=x` | `deploy-all-cloud` + `deploy-all-site` |
| **Validates** | Control plane works | HW connectivity | Operational workflow | Production readiness |
