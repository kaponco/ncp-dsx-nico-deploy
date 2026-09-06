# NICo Provisioning Protocol Flow

End-to-end sequence from operator registration through x86 host OS provisioning.
Covers both the DPU path (BlueField ARM) and the Host (x86) path where they diverge.

All column content uses NICo/upstream terminology as found in the source.

> **How NICo learns about a new BMC:** DHCP is the trigger. When a BMC powers on it
> broadcasts a DHCP DISCOVER. `nico-dhcp` relays the MAC + relay address to `nico-api`
> gRPC, which calls `find_or_create_observed_machine_interface` to assign an IP and
> persist a `machine_interface` row. `site-explorer` then picks up that IP on its next
> scan pass, probes it via Redfish, and creates the `explored_endpoint` record that
> drives the rest of the ingestion pipeline.

---

## Columns

| Column | Meaning |
|---|---|
| **#** | Phase number |
| **Phase** | NICo phase name / state transition |
| **Initiator** | The component that sends the first message |
| **Receiver** | The component that handles the message |
| **What is Sent** | High-level payload / action |
| **Protocol** | Application protocol |
| **Transport** | L3/L4 transport |
| **NICo Result** | State change in `nico-api` / DB after this step |
| **DPU Result** | Observable outcome on the DPU (BlueField) |
| **Host Result** | Observable outcome on the x86 host |

---

## Group A — BMC Registration & IP Discovery (phases -2 to 0)

Machine is registered by the operator and gets its first IP via the BMC DHCP path.
`site-explorer` confirms the endpoint is live via Redfish.

| # | Phase | Initiator | Receiver | What is Sent | Protocol | Transport | NICo Result | DPU Result | Host Result |
|---|---|---|---|---|---|---|---|---|---|
| -2 | **Operator Pre-Registration — `ExpectedMachine`** | Operator | `nico-api` REST API | `POST /v2/org/.../expected-machine` — declares the expected BMC MAC address, network segment, SKU, and optional fixed IP for the machine before it powers on | REST/JSON | HTTPS / TCP 443 | `expected_machine` row created with BMC MAC and interface policy (`Fixed` or `Retained`). If a fixed IP is set, `preallocate_expected_machine_interface` creates the `machine_interface` reservation immediately | — (machine not yet on) | — (machine not yet on) |
| -1 | **BMC DHCP — IP Acquisition** | BMC NIC (on power-on) | `nico-dhcp` | DHCP DISCOVER broadcast — source MAC is the BMC MAC, relay IP (`giaddr`) is the management network relay / switch IP | DHCPv4 | UDP broadcast / port 67 (via MetalLB LoadBalancer) | `nico-dhcp` calls `nico-api` gRPC `GetDhcpDiscovery(mac, relay_address)`. `nico-api` matches the MAC against `expected_machine` via `find_by_bmc_mac_address`, then calls `find_or_create_observed_machine_interface` → `machine_interface` row created with assigned IP, `interface_type = Bmc`. DHCP OFFER returned with IP lease (no boot file — BMC is not PXE booting) | DPU BMC receives IP lease; BMC management plane online | Host BMC receives IP lease; BMC management plane online |
| 0 | **BMC Redfish Probe — `explored_endpoint` Creation** | `site-explorer` (nico-api, background loop) | BMC Redfish API | `site-explorer` reads all `machine_interface` rows with `interface_type = Bmc` on Underlay/HostInband segments → for each new IP not yet in `explored_endpoints`, probes `GET /redfish/v1/` to confirm it is a live Redfish endpoint | Redfish (REST/JSON) | HTTPS / TCP 443 | `explored_endpoints::insert(bmc_ip, report)` — `explored_endpoint` row created with `preingestion_state = Initial` and the full Redfish inventory report | DPU BMC enumerated; DPU serial, firmware version, system UUID recorded | Host BMC enumerated; host serial, firmware version, CPU/DIMM topology recorded |

---

## Group B — Pre-Ingestion (phases 1–7)

`preingestion-manager` prepares each BMC before any OS boot is attempted.
DPU additionally goes through BFB firmware flashing via rshim.

| # | Phase | Initiator | Receiver | What is Sent | Protocol | Transport | NICo Result | DPU Result | Host Result |
|---|---|---|---|---|---|---|---|---|---|
| 1 | **BMC Discovery — Redfish Inventory Poll** | `site-explorer` (nico-api) | BMC (iDRAC / iLO / BMC) | `GET /redfish/v1/Systems` — enumerate all systems, read MAC addresses and power state | Redfish (REST/JSON) | HTTPS / TCP 443 | `explored_endpoint` row updated; `preingestion_state = Initial` | DPU BMC responds with system inventory | Host BMC responds with system inventory |
| 2 | **Pre-ingestion — Initial BMC Reset** (`PreingestionState::InitialBMCReset`) | `preingestion-manager` (nico-api) | BMC | Redfish POST to reset BMC to factory state / clear IPMI credentials | Redfish | HTTPS / TCP 443 | `preingestion_state → InitialBMCReset` | DPU BMC reboots | — |
| 3 | **Pre-ingestion — NTP Sync** (`PreingestionState::SetNtpServers`) | `preingestion-manager` | BMC | Redfish PATCH to set NTP server list | Redfish | HTTPS / TCP 443 | `preingestion_state → SetNtpServers` | DPU BMC clock synced to site NTP | Host BMC clock synced |
| 4 | **Pre-ingestion — Firmware Version Check** (`PreingestionState::RecheckVersions`) | `preingestion-manager` | BMC | Redfish GET firmware inventory | Redfish | HTTPS / TCP 443 | Firmware versions recorded; decides if BFB upgrade needed | DPU firmware version known | Host BMC firmware version known |
| 5 | **Pre-ingestion — BFB Firmware Push (DPU only)** (`PreingestionState::BfbInstallationWait`) | `preingestion-manager` | DPU rshim interface | BFB (BlueField Boot stream) image written to `/dev/rshim0/boot` via rshim | rshim / BFB binary | USB / PCIe rshim character device | `preingestion_state → BfbInstallationWait` | DPU flashes new firmware and reboots | — (host not involved) |
| 6 | **Pre-ingestion — Firmware Upgrade Wait** (`PreingestionState::UpgradeFirmwareWait`) | `preingestion-manager` | BMC | Redfish GET to poll firmware update job status | Redfish | HTTPS / TCP 443 | Waits until firmware job completes | DPU reboots into new firmware | Host: Redfish firmware job polled if applicable |
| 7 | **Pre-ingestion — Complete** | `preingestion-manager` | DB (nico-api internal) | Internal state transition — no network message | — | — | `preingestion_state → Complete`; endpoint becomes eligible for ingestion | DPU ready for network boot | Host ready for network boot |

---

## Group C — Network Boot Entry (phases 8–13)

Boot order is confirmed via Redfish, then DPU/Host NICs broadcast DHCP DISCOVER.
`nico-dhcp` serves IP leases with HTTP boot URLs pointing to `nico-pxe`.
UEFI downloads `ipxe.efi` over HTTP and chainloads the per-boot iPXE script.

| # | Phase | Initiator | Receiver | What is Sent | Protocol | Transport | NICo Result | DPU Result | Host Result |
|---|---|---|---|---|---|---|---|---|---|
| 8 | **Boot Order Verification** | `site-explorer` | BMC | Redfish GET `BootOrder` on `Systems/[id]/Bios/Settings` | Redfish | HTTPS / TCP 443 | `eligible_for_network_boot()` confirmed; machine queued for PXE | — | Host must have PXE listed in Redfish boot order |
| 9 | **DPU DHCP Discover** (`DpuInitState::Init` → boot) | DPU NIC (oob_net0) | `nico-dhcp` | DHCP DISCOVER — MAC, vendor class string (`PXEClient:Arch:00011` = ARM EFI) | DHCPv4 | UDP broadcast / port 67 | `nico-dhcp` calls `nico-api` gRPC `GetDhcpDiscovery(mac)` → receives IP + booturl | DPU waiting for DHCP OFFER | — |
| 10 | **Host DHCP Discover** | Host NIC (PXE ROM) | `nico-dhcp` | DHCP DISCOVER — MAC, vendor class string (`PXEClient:Arch:00007` = x86_64 EFI) | DHCPv4 | UDP broadcast / port 67 | `nico-dhcp` calls `nico-api` gRPC `GetDhcpDiscovery(mac)` → receives IP + booturl | — | Host waiting for DHCP OFFER |
| 11 | **DHCP OFFER + Boot URL** | `nico-dhcp` | DPU or Host NIC | DHCP OFFER: `yiaddr`=assigned IP, `siaddr`=`nico-pxe` IP, `option 67`=`http://<pxe-ip>:8080/public/blobs/internal/<arch>/ipxe.efi` | DHCPv4 | UDP unicast/broadcast / port 68 | `DhcpRecord` consumed; lease persisted | DPU receives IP lease + HTTP boot URL | Host receives IP lease + HTTP boot URL |
| 12 | **iPXE EFI Download** | DPU or Host UEFI firmware | `nico-pxe` | `GET /public/blobs/internal/aarch64/ipxe.efi` (DPU) or `…/x86_64/ipxe.efi` (Host) — served from `boot-artifacts` `emptyDir` staged by init containers | HTTP/1.1 | TCP / port 8080 | HTTP 200 + binary — no state change in NICo | DPU downloads and executes `ipxe.efi` (carbide-flavoured) | Host downloads and executes `ipxe.efi` |
| 13 | **iPXE Embedded Script Chainload** | iPXE firmware (running on DPU or Host) | `nico-pxe` | `GET /api/v0/pxe/boot?buildarch=arm64&product=BlueField` (DPU) or `…?buildarch=x86_64` (Host) — triggered by `embed.ipxe` baked into the binary | HTTP/1.1 | TCP / port 80 (via `nico-pxe-external-80` LoadBalancer) | `nico-pxe` calls `nico-api` gRPC `GetPxeInstructions(arch, client_ip, product)` | DPU waiting for iPXE script response | Host waiting for iPXE script response |

---

## Group D — Discovery Scout Boot (phases 14–18)

`nico-api` state machine dispatches a Scout boot script.
Scout boots on the DPU (`carbide.efi`) or Host (`scout.efi`), enumerates hardware,
and calls back to `nico-api` gRPC to register the machine and advance the state machine.

| # | Phase | Initiator | Receiver | What is Sent | Protocol | Transport | NICo Result | DPU Result | Host Result |
|---|---|---|---|---|---|---|---|---|---|
| 14 | **PXE State Machine Dispatch — Unknown Host** | `nico-api` (internal, triggered by step 13) | DB lookup | MAC not yet in `machine_interface_addresses`; `explored_endpoint` found → dispatch Discovery Scout | internal | — | No machine record yet; route to Discovery Scout script | — | — |
| 15 | **Discovery Scout Boot — DPU** (`DpuInitState::Init`) | `nico-pxe` HTTP response | DPU iPXE | iPXE script: `kernel …/aarch64/carbide.efi cli_cmd=auto-detect bfks=${cloudinit-url}/user-data machine_id=<id> server_uri=<api_url>` + `imgfetch carbide.root` | iPXE script (HTTP) | TCP / port 80 | State stays `DpuInitState::Init` pending Scout callback | DPU boots `carbide.efi` (Scout/agent) from `nico-pxe` | — |
| 16 | **Discovery Scout Boot — Host** (`ManagedHostState::Ready` or pre-registration) | `nico-pxe` HTTP response | Host iPXE | iPXE script: `kernel …/x86_64/scout.efi mac=<MAC> cli_cmd=auto-detect machine_id=<id> server_uri=<api_url> pxe_uri=<pxe_url>` | iPXE script (HTTP) | TCP / port 80 | State stays `Ready` (or unregistered) pending Scout callback | — | Host boots `scout.efi` |
| 17 | **Scout Kernel + Root FS Download** | `scout.efi` / `carbide.efi` running on DPU or Host | `nico-pxe` | `GET /public/blobs/internal/<arch>/scout.efi` and (DPU only) `GET /public/blobs/internal/aarch64/carbide.root` | HTTP/1.1 | TCP / port 8080 | HTTP 200 + binary payload; no state change | DPU downloads and boots Scout agent OS | Host downloads and boots Scout OS |
| 18 | **Scout Hardware Enumeration Callback** | `nico-scout` (running on DPU or Host) | `nico-api` gRPC | `RegisterMachine(machine_id, hw_inventory)` — DMI, PCI topology, GPU/DPU counts, MAC addresses | gRPC (mTLS) | TCP / port 1079 | Machine record created; `machine_interface_addresses` populated. DPU → `DpuInitState::WaitingForPlatformConfiguration`. Host → `ManagedHostState::HostInit { machine_state: Init }` | DPU registered; enters `WaitingForPlatformConfiguration` | Host registered; enters `HostInit` |

---

## Group E — DPU Provisioning (phases 19–24)

`nico-api` configures the DPU platform via Redfish and power-cycles it.
On the second PXE boot the DPU receives the HBN OS install script,
fetches cloud-init config from `nico-pxe`, and reports ready via the DPF operator.
When all DPUs on the host reach `DeviceReady`, the host advances to `HostInit`.

| # | Phase | Initiator | Receiver | What is Sent | Protocol | Transport | NICo Result | DPU Result | Host Result |
|---|---|---|---|---|---|---|---|---|---|
| 19 | **DPU Platform Configuration** (`DpuInitState::WaitingForPlatformConfiguration`) | `nico-api` state machine | BMC (Redfish) | BIOS/platform configuration via Redfish PATCH — network config, UEFI settings | Redfish | HTTPS / TCP 443 | `DpuInitState → WaitingForPlatformPowercycle` | DPU platform configured; reboot triggered | — |
| 20 | **DPU Platform Power Cycle** (`DpuInitState::WaitingForPlatformPowercycle`) | `nico-api` state machine | BMC | Redfish POST `Actions/ComputerSystem.Reset` → `ForceOff` then `On` | Redfish | HTTPS / TCP 443 | `DpuInitState → WaitingForPlatformPowerOff → WaitingForNetworkConfig` | DPU reboots; will DHCP again on next boot | — |
| 21 | **DPU Second DHCP + iPXE Boot** | DPU NIC (post power-cycle) | `nico-dhcp` → `nico-pxe` | Repeat of steps 9–13 but DPU is now registered in DB | DHCPv4 → HTTP | UDP/67 → TCP/80 | `nico-api` PXE dispatch: DPU in `DpuInitState::DpfStates { Provisioning }` | DPU receives DPF provisioning iPXE script | — |
| 22 | **DPU HBN / OS Install** (`DpuInitState::InstallDpuOs` or `DpfStates::Provisioning`) | `nico-pxe` HTTP response | DPU iPXE | iPXE script for HBN network install: `kernel carbide.efi cli_cmd=hbn-install …` + cloud-init `bfks` URL | iPXE script (HTTP) | TCP / port 80 | `DpuInitState → DpfStates { WaitingForReady }` | DPU installs HBN OS image | — |
| 23 | **DPU Cloud-Init Fetch** | DPU cloud-init (inside booted OS) | `nico-pxe` | `GET /api/v0/cloud-init/user-data` and `meta-data` | HTTP/1.1 | TCP / port 8080 | `nico-api` `GetCloudInitInstructions(client_ip)` → per-DPU user-data | DPU receives network config / credentials | — |
| 24 | **DPU DPF Operator Ready Callback** (`DpfState::WaitingForReady → DeviceReady`) | DPF operator (K8s controller) | `nico-api` watcher | Kubernetes watch event: DPF `DpuDevice` CR status → `Ready` | Kubernetes watch / gRPC | TCP (in-cluster) | `DpuInitState → DpfStates { DeviceReady }` → all DPUs ready → host transitions to `HostInit` | DPU fully provisioned; DOCA HBN running | — |

---

## Group F — Host Init & Validation (phases 25–31)

`nico-api` configures host BIOS via Redfish, validates the hardware BOM against the
assigned SKU, and boots Scout a second time for measurement collection.
On success the host enters the `Ready` pool.

| # | Phase | Initiator | Receiver | What is Sent | Protocol | Transport | NICo Result | DPU Result | Host Result |
|---|---|---|---|---|---|---|---|---|---|
| 25 | **Host Init — IPMI Over LAN Enable** (`HostInit { MachineState::EnableIpmiOverLan }`) | `nico-api` state machine | Host BMC | Redfish PATCH to enable IPMI/LAN access | Redfish | HTTPS / TCP 443 | `MachineState → WaitingForPlatformConfiguration` | — | Host BMC IPMI-over-LAN enabled |
| 26 | **Host BIOS Configuration** (`HostInit { MachineState::WaitingForPlatformConfiguration }`) | `nico-api` state machine | Host BMC | Redfish PATCH BIOS attributes — boot order, secure boot, UEFI settings | Redfish | HTTPS / TCP 443 | `MachineState → WaitingForBiosJob` | — | BIOS config job queued on host |
| 27 | **Host BIOS Job Wait** (`HostInit { MachineState::WaitingForBiosJob }`) | `nico-api` state machine | Host BMC | Redfish GET job status poll | Redfish | HTTPS / TCP 443 | When complete: `MachineState → WaitingForDiscovery` | — | Host reboots; BIOS config applied |
| 28 | **BOM Validation — Inventory Update** (`ManagedHostState::BomValidating { UpdatingInventory }`) | `nico-api` state machine | Internal DB | Cross-check Scout HW inventory against expected SKU BOM (CPUs, DIMMs, NICs, GPUs) | Internal | — | `BomValidating → WaitingForSkuAssignment` or `SkuVerificationFailed` | — | — |
| 29 | **BOM Validation — SKU Assignment** (`BomValidating::WaitingForSkuAssignment`) | Operator or auto-assign | `nico-api` REST API | `POST /v2/org/.../machine/<id>/sku` — assign a product SKU | REST/JSON | HTTPS / TCP 443 | `ManagedHostState → Validation` | — | — |
| 30 | **Machine Validation Boot** (`ManagedHostState::Validation`) | `nico-api` state machine → Redfish | Host BMC | Power on host; host PXE-boots Scout again for validation measurements | Redfish + PXE | HTTPS / UDP 67 / TCP 80 | `ValidationState → MachineValidation { WaitingForMeasurements }` | — | Host boots Scout for hardware measurement pass |
| 31 | **Validation Measurements Callback** | `nico-scout` on Host | `nico-api` gRPC | `ReportMeasurements(machine_id, measurements)` — GPU health, NIC link checks | gRPC (mTLS) | TCP / port 1079 | `ManagedHostState → Ready` (host joins the available pool) | — | Host enters pool as `Ready` |

---

## Group G — OS Provisioning (phases 32–38)

Operator or tenant assigns an instance. `nico-api` pushes network/storage config
via `nico-site-agent`, then triggers an OS PXE boot. `ipxe-renderer` renders the
OS-specific iPXE script, the installer fetches cloud-init from `nico-pxe`, and on
completion the host exits to disk with a running OS.

| # | Phase | Initiator | Receiver | What is Sent | Protocol | Transport | NICo Result | DPU Result | Host Result |
|---|---|---|---|---|---|---|---|---|---|
| 32 | **Instance Assignment** | Operator or tenant API call | `nico-api` REST API | `POST /v2/org/.../instance` — create instance, assign host + OS image | REST/JSON | HTTPS / TCP 443 | `ManagedHostState → Assigned { InstanceState::WaitingForNetworkSegmentToBeReady }` | — | — |
| 33 | **Network & Storage Config** (`InstanceState::WaitingForNetworkConfig`, `WaitingForStorageConfig`) | `nico-api` state machine | `nico-site-agent`, network config services | Push network segment / VPC config to site; configure host NICs and storage via gRPC | gRPC (mTLS) | TCP / port 1079 (site-agent) | `InstanceState → WaitingForRebootToReady` | DPU NIC VPC config applied | — |
| 34 | **OS Provisioning Boot — PXE Request** (`Assigned { InstanceState::Ready }` + `use_custom_pxe_on_boot=true`) | Host NIC | `nico-dhcp` → `nico-pxe` | Repeat DHCP + iPXE chainload (steps 9–13); PXE dispatch detects `Assigned { Ready }` + boot flag | DHCPv4 → HTTP | UDP/67 → TCP/80 | `nico-api` `GetPxeInstructions` → renders OS provisioning iPXE script via `ipxe-renderer` | — | Host receives OS-specific iPXE boot script |
| 35 | **OS iPXE Script Rendering** | `nico-api` internal (`DefaultIpxeScriptRenderer::render`) | `ipxe_template` DB record + artifact cache | Template substitution: `base_url`, `console`, `image_url`, `image_sha`; artifact cache strategy applied (`CacheAsNeeded` / `CachedOnly` / `RemoteOnly`) | Internal | — | Rendered iPXE script returned to `nico-pxe`; SHA-256 hash validated against stored record | — | — |
| 36 | **OS Kernel + Initrd / qcow Fetch** | Host iPXE (running rendered script) | `nico-pxe` or remote artifact store | `GET` OS kernel, initrd, or `GET` qcow image URL — per artifact cache strategy | HTTP/1.1 or HTTPS | TCP / port 80 or 443 | Artifacts served from local cache or proxied from upstream URL | — | Host downloads OS installer payload |
| 37 | **Cloud-Init Delivery (Ubuntu Autoinstall / OS)** | cloud-init inside booted installer | `nico-pxe` | `GET /api/v0/cloud-init/user-data` and `meta-data` | HTTP/1.1 | TCP / port 8080 | `nico-api` `GetCloudInitInstructions(client_ip)` → per-instance user-data | — | Host installer receives autoinstall config / SSH keys / network settings |
| 38 | **Host OS Install Completion → Exit to Disk** | OS installer (post-install reboot) | `nico-pxe` | iPXE boot request; `nico-api` dispatch: `Assigned { Ready }` + boot flag cleared → `exit_instructions` | HTTP/1.1 | TCP / port 80 | `nico-api` returns `exit` iPXE script; `InstanceState → Ready` (no more PXE boots) | — | Host boots from local disk; OS running |

---

## Key Component Map

| Component | Role in Flow |
|---|---|
| `site-explorer` | Discovers BMC endpoints via Redfish (phases 0, 1, 8) |
| `preingestion-manager` | Manages BMC reset, NTP, BFB firmware, firmware upgrade (phases 2–7) |
| `nico-dhcp` | NICo's own Rust DHCP server; hands out IPs for BMC (phase -1) and PXE boot URLs (phases 9–11); calls `nico-api` gRPC for every DISCOVER |
| `nico-pxe` | Axum HTTP server; serves iPXE binaries and boot scripts; calls `nico-api` gRPC `GetPxeInstructions` for every boot request (phases 12–16, 34–38) |
| `nico-api` | Core gRPC API (Rust); owns all state machines; answers all DHCP and PXE queries; receives Scout callbacks (phases 18, 23, 31, 37) |
| `nico-scout` / `carbide.efi` | Lightweight agent booted via iPXE on DPU/Host; enumerates hardware and calls back to `nico-api` (phases 17–18, 30–31) |
| `ipxe-renderer` | Library inside `nico-api`; renders named iPXE templates with per-OS parameter + artifact substitution (phase 35) |
| DPF operator | Kubernetes controller managing DPU device lifecycle; `nico-api` watches its CRs (phase 24) |
| `nico-site-agent` | Relay between cloud REST workflow engine and site `nico-api`; carries network/storage config (phase 33) |

---

## State Progression Summary

```
[DPU]                                          [Host]
── Group A: BMC Registration & IP Discovery ──────────────────────────────────
Operator registers ExpectedMachine (BMC MAC + segment)
  ↓ BMC powers on → DHCP DISCOVER
  ↓ nico-dhcp → nico-api → machine_interface row (IP assigned)
  ↓ site-explorer probes BMC IP via Redfish → explored_endpoint created

── Group B: Pre-Ingestion ────────────────────────────────────────────────────
explored_endpoint.preingestion_state:
  Initial → InitialBMCReset → SetNtpServers
  → RecheckVersions → BfbInstallationWait (DPU only)
  → UpgradeFirmwareWait → Complete

── Groups C + D: Network Boot Entry & Discovery Scout ────────────────────────
ManagedHostState:
  DPUInit { Init }                               (Host also boots Scout here)

── Group E: DPU Provisioning ─────────────────────────────────────────────────
  DPUInit { WaitingForPlatformConfiguration }
    → DPUInit { WaitingForPlatformPowercycle }
    → DPUInit { DpfStates { Provisioning } }
    → DPUInit { DpfStates { WaitingForReady } }
    → DPUInit { DpfStates { DeviceReady } }
  ──────────────────────────────────────────────►

── Group F: Host Init & Validation ───────────────────────────────────────────
                                          HostInit { MachineState::Init }
                                            → HostInit { EnableIpmiOverLan }
                                            → HostInit { WaitingForPlatformConfiguration }
                                            → HostInit { WaitingForBiosJob }
                                            → HostInit { WaitingForDiscovery }
                                          BomValidating { UpdatingInventory }
                                            → BomValidating { WaitingForSkuAssignment }
                                          Validation { WaitingForMeasurements }
                                          Ready

── Group G: OS Provisioning ──────────────────────────────────────────────────
                                          Assigned { WaitingForNetworkSegmentToBeReady }
                                            → Assigned { WaitingForNetworkConfig }
                                            → Assigned { WaitingForStorageConfig }
                                            → Assigned { WaitingForRebootToReady }
                                            → Assigned { Ready }  ← OS PXE boot
                                            → Assigned { Ready }  ← exit to disk
```
