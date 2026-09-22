# DPU Onboarding — State of All Changes Made

**Machine under test:** TBD — fill in after Step 1/5c Redfish probes
**Last update:** 2026-09-22
**Status:** BLOCKED — DPU stuck at `dpunotready.init`, waiting on lab network (L2/switch) setup

DPU BMC IP: `10.6.136.28`, creds: `root/bluefield012`
Host BMC IP: `10.6.136.44`, creds: `root/calvin`

---

## Current Runbook Position

**Last completed step:** Step 6

Steps:
- [x] Step 0 — Network Prerequisites — **NOT DONE — BLOCKING**
- [x] Step 1a — Read DPU System Info via Redfish
- [x] Step 1b — Read Host BMC System Info via Redfish
- [x] Step 1c — Read Host BMC MAC address
- [x] Step 2 — Read DPU Network Interface MACs
- [x] Step 3a — Seed DPU BMC credential in Vault
- [x] Step 3b — Seed Host BMC credential in Vault
- [x] Step 4a — Verify BMC Connectivity
- [x] Step 4b — Acquire API Token
- [x] Step 4c — Find Site ID
- [x] Step 4d — Pre-register DPU expected-machine
- [x] Step 5a — Verify DPU Preingestion
- [x] Step 5b — Register Host BMC
- [x] Step 6 — Verify DPU Data Plane Network Reachability
- [ ] Step 7 — Check Machine State and DPU OS — **BLOCKED** (DPU at `dpunotready.init`)
- [ ] Step 8 — Define Host Lifecycle Profile
- [ ] Step 9 — Wait for Host Discovery — **BLOCKED** (same L2 issue)
- [ ] Step 10 — Trigger Host OS Provisioning

---

## Discovered Values (fill in as you go)

| Value | Source | Result |
|---|---|---|
| DPU Redfish system ID | Step 1a | `Bluefield` |
| DPU serial number | Step 1a | `MT2337XZ05A7` |
| DPU UUID | Step 1a | `00000000-0000-0000-0000-000000000000` |
| Host Redfish system ID | Step 1b | `System.Embedded.1` |
| Host serial number | Step 1b | `MXFC40029800IU` |
| Host model | Step 1b | Dell PowerEdge R750 (x86_64) |
| Host BMC MAC | Step 1c | `c8:4b:d6:86:f3:a0` |
| DPU eth0 MAC | Step 2 | `02:de:1f:c2:c5:11` |
| DPU eth1 MAC | Step 2 | `02:31:dd:95:f6:18` |
| DPU oob0 MAC | Step 2a | `a0:88:c2:75:91:8e` |
| DPU BMC Manager MAC | Step 2b | `a0:88:c2:75:91:8f` (use this for registration) |
| Site ID | Step 4c | `f7b39b3f-cc6e-4b1d-8fc7-468eeca4ff35` |
| Expected-machine ID (DPU) | Step 4d | `a62072cb-875d-4eb6-a980-bcc5d59df8f1` |
| Expected-machine ID (host) | Step 5b | `7d98697b-c6f4-4db3-be2a-2293a120517f` |
| Expected-machine ID (host) | Step 5b | `7d98697b-c6f4-4db3-be2a-2293a120517f` |
| DPU Machine ID | Step 7 | `fm100ds86sr033o4b0npig0nqmfpqh6v5b6uv3fu1plfq7vuq3gc4o59rdg` |
| Host Machine ID | Step 7 | `fm100ps86sr033o4b0npig0nqmfpqh6v5b6uv3fu1plfq7vuq3gc4o59rdg` |

---

## What NICo Did (automatic, after Steps 1–6)

NICo's machine state controller successfully processed the DPU through these states:

1. **Initializing** — site-explorer picked up the DPU
2. **Configuring** — configured DPU settings via BMC
3. **EnableRshim** — enabled RShim on the DPU
4. **DisableSecureBoot** — checked secure boot (not available on this DPU, rebooted as workaround)
5. **SetUefiHttpBoot** — configured UEFI HTTP Boot on the DPU
6. **RebootAllDPUS** — rebooted the DPU (restart verified)
7. **DPUInit.Init** — **CURRENT STATE** — waiting for DPU agent to connect

DPU firmware: BMC `BF-26.04-8`, NIC `32.49.1014`, UEFI `4.14.0-8`, OS `bf-bundle-3.4.0-92_26.04_ubuntu-24.04_64k_prod`

## Blocker: L2 Network Connectivity

The DPU was rebooted with HTTP Boot enabled but its data plane (eth0/eth1) reaches the
**lab DHCP** server, not NICo's DHCP. Without L2 connectivity to NICo's DHCP/PXE services:
- The DPU can't HTTP Boot → falls back to its existing Ubuntu OS (no NICo agent)
- The host can't PXE Boot through the DPU → NICo can't discover the host

**Action required:** Ask the lab team to configure the switch so that the DPU data plane
ports can reach NICo's DHCP/PXE/DNS services. See Step 0 in the runbook for details.

**NICo services to reach:**
- DHCP: `nico-dhcp` svc, UDP 67/68
- PXE: `nico-pxe` svc, TCP 8080
- DNS: `nico-dns` svc, UDP/TCP 53

## Changes Applied

_(none yet — will be recorded as steps are executed)_
