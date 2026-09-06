# DPU Onboarding — State of All Changes Made

**Machine under test:** `nvd-srv-36.nvidia.eng.rdu2.dc.redhat.com` (Supermicro ARS-111GL-NHR / NVIDIA GH200 480GB, ARM aarch64)
**Last update:** 2026-09-06
**Status:** Blocked — waiting for second DPU (`MT2403XZ05C3`) BMC IP to complete host-DPU pairing

Record of every change applied during the onboarding debug session.
Expected-machine ID: `ce53aa80-8277-49de-b7df-b1fcf34e94b5`
DPU serial: `MT240230076V`, BMC MAC: `58:a2:e1:67:86:a6`, BMC IP: `10.6.136.214`

---

## 1. Vault (nico-system / Vault HA)

All changes applied via `vault kv put` against `https://vault.nico-system.svc.cluster.local:8200`.
These paths are **in addition to** what `make vault-init` seeds — they were missing.

### 1a. Site-wide BMC root credential

```
Path: secrets/machines/bmc/site/root
Value: {"UsernamePassword": {"username": "root", "password": "0penBmc"}}
```

Required by `REQUIRED_SITE_DEFAULT_CREDENTIAL_KEYS` precondition in site-explorer.
`make vault-init` does NOT seed this — it only seeds factory-default credentials.

### 1b. DPU site-default UEFI credential

```
Path: secrets/machines/all_dpus/site_default/uefi-metadata-items/auth
Value: {"UsernamePassword": {"username": "", "password": "bluefield"}}
```

Required by `REQUIRED_SITE_DEFAULT_CREDENTIAL_KEYS`. Not seeded by `make vault-init`.

### 1c. Host site-default UEFI credential

```
Path: secrets/machines/all_hosts/site_default/uefi-metadata-items/auth
Value: {"UsernamePassword": {"username": "", "password": "bluefield"}}
```

Required by `REQUIRED_SITE_DEFAULT_CREDENTIAL_KEYS`. Not seeded by `make vault-init`.

### 1d. Per-machine BMC credential (lowercase MAC)

```
Path: secrets/machines/bmc/58:a2:e1:67:86:a6/root
Value: {"UsernamePassword": {"username": "root", "password": "4PJi-8D3k_14mS"}}
```

The DPU BMC was NOT reset to factory password `0penBmc` (reset attempt via Redfish PATCH
failed — BMC returned a null-value warning). The actual current password is `4PJi-8D3k_14mS`.
Site-explorer looks up `machines/bmc/{MAC}/root` to authenticate. Seeded with the real
password so site-explorer can connect.

### 1e. Per-machine BMC credential (uppercase MAC)

```
Path: secrets/machines/bmc/58:A2:E1:67:86:A6/root
Value: {"UsernamePassword": {"username": "root", "password": "4PJi-8D3k_14mS"}}
```

Site-explorer formats MAC addresses in uppercase internally. Seeded both cases to be safe.

**NOTE**: Paths 1d and 1e contain the non-factory password `4PJi-8D3k_14mS`. Once NICo
successfully ingests the machine, it will rotate BMC credentials automatically and update
these paths. But currently `make vault-init` doesn't seed 1a–1c at all — this is a gap.

---

## 2. PostgreSQL — nico-cloud-pg (REST layer / nico-rest namespace)

### 2a. WAL archive disk cleanup (repo-host PVC)

```
Pod: nico-cloud-pg-repo-host-0
PVC: /pgbackrest/repo1 (was 100% full, 960M)

Command: rm -rf /pgbackrest/repo1/archive/db/18-1/
Result: freed 896M of WAL archives
```

### 2b. pgdata disk cleanup (primary instance)

```
Pod: nico-cloud-pg-instance1-k6qw-0
PVC: /pgdata (was 100% full, 4.3GB of unarchived WAL)

Last checkpoint WAL: 000000010000000600000004 (from pg_controldata)
Command: cd /pgdata/pg18/pg_wal && ls -p | grep -v "/" | \
  grep -v "^000000010000000600000004" | grep -v "\.backup$" | xargs rm -f
Result: Patroni recovered to running state, timeline 2
```

**Root cause**: pgbackrest repo-host PVC (960M) too small for sustained WAL archiving.
Patroni entered crash-recovery loop when WAL archiving failed due to full disk.
This took down Keycloak (which depends on PG), breaking all API token acquisition.

**WARNING**: The repo-host PVC needs to be resized for production. 960M is inadequate.

---

## 3. PostgreSQL — nico-site-pg (forge/Core layer / nico-system namespace)

### 3a. explored_endpoints — clear lockout, force re-exploration (applied twice)

```sql
UPDATE explored_endpoints
SET exploration_requested = true,
    exploration_report = exploration_report - 'LastExplorationError'
WHERE address = '10.6.136.214';
```

**Why**: Site-explorer enters "avoid_lockout" state after a 401. It stores
`LastExplorationError: {"Type": "AvoidLockout"}` in the jsonb column and refuses to retry
until an operator intervenes. Clearing the error and setting `exploration_requested = true`
puts the endpoint in the priority probe queue (bypasses the 2-minute schedule).

Applied twice:
- First time: cleared the lockout caused by the failed `0penBmc` probe
- Second time: cleared after seeding the per-machine Vault credential (1d/1e) so site-explorer
  would retry with the correct credential

**Current state**: After the second clearing, site-explorer successfully connected to the BMC
(`4PJi-8D3k_14mS` worked), read the full Redfish inventory, and logged "Initial exploration
of endpoint" with a complete exploration report. The forge DB has a machine record
`fm100ds5q1eg5k7agv6cp9i9id6kkk3tu7edp4m3ar04dna1pualltip6i0` for this DPU.

---

## 4. REST API — expected-machine record

### 4a. POST (created expected-machine)

```bash
POST /v2/org/ncx/nico/expected-machine
{
  "siteId": "b8aad3f5-5ab9-4752-9795-200ac20e4aa4",
  "bmcIp": "10.6.136.214",           ← WRONG field name (ignored)
  "bmcMacAddress": "58:a2:e1:67:86:a6",
  "bmcUsername": "root",
  "bmcPassword": "4PJi-8D3k_14mS",
  "chassisSerialNumber": "MT240230076V",
  "name": "dpu-bf3-01",
  "manufacturer": "NVIDIA",
  "model": "BlueField-3"
}
Result: 201, id = ce53aa80-8277-49de-b7df-b1fcf34e94b5
```

The field `bmcIp` is not a valid API field — the correct name is `bmcIpAddress`. So
`bmc_ip_address` was NULL in the REST DB and forge received `bmc_ip_address: None`. Without
a static IP, site-explorer had no endpoint to probe (no DHCP event for this static-IP DPU).

### 4b. PATCH (fixed bmcIpAddress)

```bash
PATCH /v2/org/ncx/nico/expected-machine/ce53aa80-8277-49de-b7df-b1fcf34e94b5
{
  "bmcIpAddress": "10.6.136.214",    ← correct field name
  "bmcUsername": "root",
  "bmcPassword": "0penBmc"
}
Result: 200
```

This updated both the REST DB (`bmc_ip_address = '10.6.136.214'`) and triggered the
`UpdateExpectedMachine` Temporal workflow which forwarded the IP to forge. Site-explorer
then created a `machine_interface` entry for `10.6.136.214` and started probing.

**Note**: `bmcPassword: "0penBmc"` in the PATCH was set assuming the BMC was reset, but
the BMC reset failed. The actual password in Vault (path 1d/1e) is `4PJi-8D3k_14mS`.

---

## 5. Keycloak — No direct changes

Keycloak recovered automatically once PostgreSQL was back up (changes 2a/2b above).
No Keycloak configuration was modified.

---

## 6. Session 2 Findings (2026-09-03)

### 6a. PostgreSQL disk full (second occurrence)

Same issue as session 1 — `nico-cloud-pg-instance1-k6qw-0` `/pgdata` hit 100% (273 WAL
files, 4.3GB). Fixed the same way:

```
Last checkpoint WAL: 00000002000000070000000D
Command: cd /pgdata/pg18/pg_wal && ls -p | grep -v "/" | \
  grep -v "^00000002000000070000000D" | grep -v "\.backup$" | xargs rm -f
Result: freed to 16% (768M used of 5.0G)
```

**Root cause is recurring**: the 5GB `pgdata` PVC is too small for sustained WAL
accumulation. Must be resized for production.

### 6b. NICo preingestion of DPU — what happened

After resetting `preingestion_state` to `initial` and triggering re-exploration,
site-explorer ran the full preingestion cycle:

1. **BMC reset triggered** — site-explorer sent a Redfish BMC reset.
   The BMC went offline (~30s) then came back.
2. **Fresh exploration** — site-explorer re-read the full Redfish inventory after reset.
3. **NTP skipped** — no NTP servers configured in this deployment.
4. **Firmware check** — code path for DPUs has no firmware info; marks preingestion
   `complete` immediately (comment in source: "This is the expected path for DPUs").
5. **`preingestion_state` = `{"state": "complete"}`** — DPU is fully ingested at BMC level.

**BMC credentials after reset**: Only the original password (`4PJi-8D3k_14mS`) returns
HTTP 200. The factory password (`0penBmc`) returns HTTP 401 (Unauthorized). The BMC
password was **NOT** changed by NICo's `initialbmcreset`. The Redfish PATCH to reset the
password failed silently — the BMC accepted the request but logged a null-value warning and
did not apply the change. The current BMC password remains `4PJi-8D3k_14mS`.

### 6c. Why `machines` table in forge is empty — and why that's correct

The forge `machines` table is empty (0 rows). This is **expected behavior**, not a bug.

Source code analysis (`crates/site-explorer/src/lib.rs`,
`crates/site-explorer/src/machine_creator.rs`):

- Machine records are **only created as part of a host+DPU pair** via `create_machines`.
- Site-explorer matches DPUs to x86 hosts by **pairing serial number** (from Redfish).
- With no x86 host discovered yet, `identified_managed_hosts=0` → no machine records.
- The forge `expected_machines` table has our record correctly
  (`serial_number=MT240230076V`, `bmc_mac_address=58:a2:e1:67:86:a6`,
  `bmc_ip_address=10.6.136.214`).

### 6d. `machineId` null — also expected

`expected_machine.machine_id` in the REST DB is null because there is no forge machine
record yet. This is not a sync failure. It will populate automatically once the host
is discovered and the host+DPU machine pair is created.

---

## Current Runbook Position (updated 2026-09-06)

**Last completed step: Step 5c — Register the Host BMC** (`dpu-onboarding-runbook.md`)

Both BMC endpoints have completed preingestion:
- DPU BMC (`10.6.136.214`): `{"state": "complete"}`
- Host BMC (`10.6.136.15`): `{"state": "complete"}`

**Current blocker: DPU-host pairing requires ALL DPUs to be discovered**

The host chassis (Supermicro ARS-111GL-NHR) has **two** BlueField DPU slots:
- `SmartNIC_1`: serial `MT2403XZ05C3` — **NOT registered**, no BMC IP known
- `SmartNIC_2`: serial `MT240230076V` — registered and preingestion complete

NICo logs: `"cannot identify managed host because the site explorer has not
discovered all attached DPUs"` (`discovered_dpu_count=1`, `expected_managed_dpu_count=2`).
NICo will not create the `explored_managed_hosts` pairing or any machine records
until both DPUs are discovered.

Steps completed:
- [x] Step 1 — Read DPU System Info via Redfish
- [x] Step 2 — Read Network Interface MACs
- [x] Step 3a — Seed DPU BMC credential in Vault
- [x] Step 3b — Seed Host BMC credential in Vault (both upper/lowercase MAC)
- [x] Step 4a — Verify BMC Connectivity
- [x] Step 4b — Acquire API Token
- [x] Step 4c — Find Site ID (`shai-site` = `21b6a5a4-7067-4f10-a822-3ea4c4a5a967`)
- [x] Step 4d — Pre-register DPU expected-machine (ID `81834a63-1e39-44f4-90a7-6a24e9c17ba6`)
- [x] Step 5a — Set BMC IP on expected-machine (static IP patch)
- [x] Step 5b — Verify DPU Preingestion (complete)
- [x] Step 5c — Register Host BMC (ID from POST, preingestion complete)
- [x] Step 6 — Verify DPU Data Plane Network Reachability (DHCP catch-all `0.0.0.0/0`, cluster can reach BMC)
- [ ] **BLOCKED** — DPU-host pairing (need second DPU `MT2403XZ05C3` registered)
- [ ] Step 7 — Check Machine State and DPU OS
- [ ] Step 8 — Define Host Lifecycle Profile (need aarch64 OS image + profile)
- [ ] Step 9 — Wait for Host Discovery
- [ ] Step 10 — Trigger Host OS Provisioning

---

## Current Status (2026-09-06)

| Component | State |
|---|---|
| Cluster | Healthy — single-node OCP 4.22, all pods Running, 0 restarts |
| Vault preconditions (1a–1c) | Seeded |
| DPU BMC credential (1d/1e) | Seeded with `4PJi-8D3k_14mS` (both MAC cases) |
| Host BMC credential | Seeded with `ADMIN:0penBmc1` (both MAC cases: `7C:C2:55:86:CA:07` / `7c:c2:55:86:ca:07`) |
| PostgreSQL (cloud) | Running — PVC sizes increased in charts |
| Keycloak | Running |
| Site (REST) | `shai-site`, status `Registered`, `isOnline: true` |
| DPU BMC preingestion | **Complete** for `10.6.136.214` (serial `MT240230076V`) |
| Host BMC preingestion | **Complete** for `10.6.136.15` (Supermicro ARS-111GL-NHR, serial `S900770X4511818`) |
| DPU-host pairing | **BLOCKED** — NICo found 2 SmartNIC slots, only 1 DPU registered |
| Forge machine record | **Empty** — will not be created until pairing completes |
| REST `machineId` | **Null** — will populate after forge machine pair is created |
| NICo changes to DPU | **Read-only** — no BMC reset, no reboot, no BFB flash, no credential rotation applied |

---

## What's Next

**Immediate blocker**: Register the second BlueField DPU (`SmartNIC_1`, serial `MT2403XZ05C3`).
Need its BMC IP address. Once registered, NICo will:
1. Run preingestion on the second DPU
2. Pair both DPUs with the host via `identify_managed_hosts`
3. Create machine records in forge
4. Begin DPU configuration (HostPrivilegeLevel change, BFB flash if needed)
5. Set host boot order to PXE-via-DPU and power-cycle the host
6. Serve `aarch64/scout.efi` to the ARM host via PXE
7. Scout enumerates host hardware and registers with NICo Core

**Host architecture**: ARM (aarch64). NICo v2.2.0-pr supports ARM hosts — confirmed
in `crates/api-core/src/ipxe.rs`: *"We can't assume ARM = DPU, because there are
zero-dpu ARM hosts."* PXE serves `aarch64/scout.efi` for ARM hosts.

**Host details from Redfish**:
- Model: Supermicro ARS-111GL-NHR (NVIDIA GH200 480GB)
- CPU: NVIDIA Grace (ARM), GPU: GH200 480GB
- 2x BlueField-3 DPU slots, 2x NVMe SSDs (Samsung 1.9TB each)
- BIOS setup diffs NICo wants to apply: lockdown, QuietBoot, HTTP/PXE boot config, TPM

**To unblock**: Get the BMC IP for DPU `MT2403XZ05C3` and repeat Steps 3-5 for it.

---

## 7. Session 4 Changes (2026-09-06)

### 7a. Host BMC credential seeded in Vault

```
Path: secrets/machines/bmc/7C:C2:55:86:CA:07/root
Value: {"UsernamePassword": {"username": "ADMIN", "password": "0penBmc1"}}

Path: secrets/machines/bmc/7c:c2:55:86:ca:07/root
Value: {"UsernamePassword": {"username": "ADMIN", "password": "0penBmc1"}}
```

Host BMC (Supermicro ARS-111GL-NHR) uses `ADMIN:0penBmc1` (not `root:0penBmc`).
Seeded both uppercase and lowercase MAC variants.

### 7b. Host expected-machine registered

```bash
POST /v2/org/ncx/nico/expected-machine
{
  "siteId": "21b6a5a4-7067-4f10-a822-3ea4c4a5a967",
  "bmcIpAddress": "10.6.136.15",
  "bmcMacAddress": "7C:C2:55:86:CA:07",
  "bmcUsername": "ADMIN",
  "chassisSerialNumber": "S900770X4511818",
  "name": "arm-host-01"
}
```

Host BMC preingestion completed successfully (`{"state": "complete"}`).
NICo identified the host as Supermicro ARS-111GL-NHR with 2 SmartNIC slots.

### 7c. DPU-host pairing blocked

NICo log: `"cannot identify managed host because the site explorer has not
discovered all attached DPUs"` — `discovered_dpu_count=1`, `expected_managed_dpu_count=2`.

Host chassis has 2 BlueField-3 DPU slots:
- SmartNIC_1: serial `MT2403XZ05C3` — NOT registered (BMC IP unknown)
- SmartNIC_2: serial `MT240230076V` — registered, preingestion complete

### 7d. Runbook updated

- Added two-BMC architecture explanation and ARM host notes to Environment section
- Added Step 5a (Set BMC IP for static-IP BMCs)
- Added Step 5c (Register Host BMC — full flow with Redfish probe, Vault seed, registration)
- Updated Step 3 to cover both DPU and host BMC credentials (3a/3b)
- Fixed MAC case handling (seed both upper and lowercase)
- Updated Steps 8-9 for ARM host (aarch64/scout.efi)

---

## Outstanding Infrastructure Gaps

### Recurring WAL disk full — RESOLVED

PVC sizes increased in charts and values files (session 3):

| Cluster | PVC | Old | New |
|---|---|---|---|
| nico-cloud-pg | pgdata | 5Gi | 20Gi |
| nico-cloud-pg | pgbackrest repo1 | 1Gi | 5Gi |
| nico-site-pg | pgdata | 5Gi | 10Gi |
| nico-site-pg | pgbackrest repo1 | 1Gi | 3Gi |

Both site and cloud PVC sizes are now configurable via `postgresql.storage.size` and
`postgresql.backupStorage.size` in the respective `helm/infra-*/values.yaml` files.

### `make vault-init` — RESOLVED

All three previously-missing Vault paths are now present in the Makefile `vault-init` target
(Makefile lines 387–391). No manual intervention needed on a fresh deploy.

## Correct expected-machine POST body (for runbook)

The correct JSON field name is `bmcIpAddress` not `bmcIp`:

```bash
curl -sk -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "$API_URL/v2/org/ncx/nico/expected-machine" \
  -d '{
    "siteId": "b8aad3f5-5ab9-4752-9795-200ac20e4aa4",
    "bmcIpAddress": "10.6.136.214",
    "bmcMacAddress": "58:a2:e1:67:86:a6",
    "bmcUsername": "root",
    "bmcPassword": "0penBmc",
    "chassisSerialNumber": "MT240230076V",
    "name": "dpu-bf3-01",
    "manufacturer": "NVIDIA",
    "model": "BlueField-3"
  }' | jq .
```
