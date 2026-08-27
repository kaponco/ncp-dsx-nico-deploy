<!--
SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Testing NICo with machine-a-tron (No Hardware Required)

machine-a-tron is NICo's built-in simulation tool. It runs entirely in the
cluster, spawns virtual BMC endpoints (bmc-mock, a Redfish mock server),
sends simulated DHCP requests, and drives the full NICo state machine — no
physical servers, switches, or OOB network required.

This guide takes a site profile from a fresh install to **NoDpu hosts in
`Ready` state** (2, by default — see `host_count` in Configuration
Reference).

## Quick Start

Prerequisite: the site profile is deployed **with the machine-a-tron test
overlay** — `make deploy-site MAT=1`. The `MAT=1` flag layers
`helm/values/nico-core-mat.yaml`, which supplies the emulator's site config
(RBAC/host-discovery bypass flags, emulator networks, bmc-mock). Without it
`make deploy-site` installs a production-safe profile with `siteConfig`
disabled and machine-a-tron will not progress. machine-a-tron's Kubernetes
resources are already wired into the site chart's kustomize render, so they
exist as soon as the site profile installs — they just need an image and
some credentials before anything progresses.

```bash
make build-machine-a-tron       # ~10 min: compiles the Rust binary in-cluster
make bootstrap-machine-a-tron   # seeds BMC/UEFI credentials bmc-mock expects (idempotent)
make machine-a-tron-status      # poll this — expect Ready within 5-10 min
```

`make machine-a-tron-status` runs `nico-admin-cli managed-host show`.
Expect one row per configured host (2, by default — see `host_count` in
Configuration below), each ending in `Ready`:

```
+---+-------------------------------------------------------------+-------+
|   | Machine IDs (H/D)                                           | State |
+===+=============================================================+=======+
| H | fm100httli6fgcnklvrotjdcuj4oriv04ufsjfgkrs2m885po661hs54p6g | Ready |
+---+-------------------------------------------------------------+-------+
| H | fm100htvsnbobe6rf86cnhrgjv07auh489f58s4jm9abau4utao6om9d8hg | Ready |
+---+-------------------------------------------------------------+-------+
```

If a row isn't progressing, jump to Troubleshooting below.

## What This Tests, and What It Doesn't

| Capability | Covered |
|---|---|
| DHCP discovery, Redfish exploration, BMC credential rotation, BIOS config | Yes |
| NoDpu host reaching `Ready` | Yes |
| DPU discovery/boot (`os_fsm: DpuAgent`, reaches `MachineUp`) | Yes |
| DPU-equipped **host** reaching `Ready` | **No** — structural limitation #1 |
| Tenant instance allocation for a NoDpu host (flat VPC, `HostInband` segment) | Yes — see [Allocating a NoDpu Host to a Tenant](#allocating-a-nodpu-host-to-a-tenant) |
| Real DHCP relay/switches, vendor Redfish quirks, real BMC timing, physical network (MetalLB/VLAN/OOB) | No — all simulated |

**Structural limitations (not bugs — don't try to fix these):**

1. **DPU-equipped hosts (`dpu_per_host_count > 0`) never reach `Ready`.**
   machine-a-tron simulates the DPU-side agent but not a host-side Scout
   agent. Getting past `WaitingForCleanup/HostCleanup` requires a real
   Scout (boots on the bare-metal host OS after PXE, wipes storage,
   reboots, calls back into `nico-api`) to set `last_cleanup_time` —
   nothing ever does that for a machine-a-tron host, so it sits in
   `HostCleanup` forever, retried every ~2s with zero progress.

As of `v2.2.0-pr`, machine-a-tron always declares a `HostInband`
`ExpectedInterface` for the host NIC and simulates a Scout agent well
enough to complete tenant allocation — the old limitation ("NoDpu hosts
can't be allocated, `instance allocate`'s picker requires a mellanox-vendor
NIC") no longer applies. That mellanox check is CLI-side cosmetic filtering
only; it never reflected a server-side restriction (see `instance allocate
--flat-vpc-id`, added specifically for zero-DPU machines).

## Configuration Reference

The working config is already checked in — you shouldn't need to touch
these files for a standard 2-host NoDpu run. Reference them if you're
changing host counts, adding DPU groups, or debugging.

**`helm/kustomize/nico-core/machine-a-tron.yaml`**
(`mat.toml`, in the ConfigMap):

```toml
carbide_api_url = "https://nico-api.nico-system.svc.cluster.local:1079"
interface = "NOTUSED"              # required but unused with use_single_bmc_mock
use_pxe_api = true                 # simulate PXE via API, no real PXE server needed
use_single_bmc_mock = true         # required for K8s: all BMCs behind one Service
bmc_mock_port = 1266
mock_bmc_ssh_server = true
persist_dir = "/tmp/machine-a-tron-data"   # emptyDir — resets on pod restart
register_expected_machines = true  # auto-registers mock hosts as ExpectedMachines

[machines.config]
host_count = 2
dpu_per_host_count = 0             # 0 = NoDpu mode; auto-registers dpu_mode: NoDpu
oob_dhcp_relay_address = "192.168.2.1"
admin_dhcp_relay_address = "192.168.252.1"
# Must match [networks.hostinband] in nicoApiSiteConfig below. Required as
# of v2.2.0-pr: machine-a-tron always declares a HostInband ExpectedInterface
# for the host NIC, so without a matching relay + segment, DHCP on that NIC
# fails with "not of the expected type host_inband" and hosts never reach Ready.
host_inband_dhcp_relay_address = "192.168.253.1"
```

One gotcha if you edit this: **ConfigMap changes don't auto-apply** — there's
no Reloader watching it. After editing + redeploying, also run:
`oc rollout restart deployment/machine-a-tron -n nico-system`
(older versions of this guide referenced a `template_dir` setting — that
directory no longer exists in the image as of `v2.2.0-pr` and the field has
been removed entirely, upstream and here).

For mixed scenarios, add more `[machines.<name>]` sections (each DPU group
will boot its DPUs but the host still can't reach `Ready`, per limitation
#1 above).

**`helm/values/nico-core-mat.yaml`** (the `MAT=1` test overlay)
(`nico-core.nico-api.siteConfig.nicoApiSiteConfig`) — every line here is a
hard requirement, not tuning:

```toml
bypass_rbac = true
initial_domain_name = "nico.local"   # without this, [networks.*] below are silently never created
attestation_enabled = false          # no real Scout to send measured-boot/TPM reports
tpm_required = false
# machine-a-tron's simulated Scout agent calls discover_machine from the
# pod's real (non-simulated) source IP, which never matches a DHCP-assigned
# machine_interface address. Without this, host discovery permanently fails
# once a host declares a HostInband interface (v2.2.0-pr, always). Test/dev
# only — see crates/api-core/src/handlers/machine_discovery.rs upstream.
allow_insecure_discovery = true

[site_explorer]
run_interval = "10s"
allow_zero_dpu_hosts = true          # without this, NoDpu discoveries are dropped on the floor
bmc_proxy = "machine-a-tron-bmc-mock.nico-system.svc.cluster.local:1266"

[networks.oob]                       # must cover mat.toml's oob_dhcp_relay_address
type = "underlay"
prefix = "192.168.2.0/24"
gateway = "192.168.2.1"
mtu = 1500
reserve_first = 10

[networks.admin]                     # must cover mat.toml's admin_dhcp_relay_address
type = "admin"
prefix = "192.168.252.0/24"
gateway = "192.168.252.1"
mtu = 9000
reserve_first = 10

[networks.hostinband]                # must cover mat.toml's host_inband_dhcp_relay_address
type = "hostinband"                  # NOT "host_inband" — this config enum is lowercase, no underscore
prefix = "192.168.253.0/24"
gateway = "192.168.253.1"
mtu = 9000
reserve_first = 10
```
## Vault Prerequisites

`nico-api` needs three things enabled in Vault before machine-a-tron can
work at all — `make vault-init` sets all three up. Unlike the old
Helm-hook Job, this always re-applies policy/role/AppRole configuration
on every run (not just first-ever init), so it's safe to re-run against
an already-initialized Vault:

1. **KV v2** at `secrets/` — BMC/DB credential storage.
2. **PKI** at `nicoca/` with a `nico-cluster` role (`require_cn=false`,
   `allowed_uri_sans=spiffe://*`) — needed for `DiscoverMachine` to issue
   machine/DPU mTLS certs, independent of `attestation_enabled`. The CA is
   imported from the shared `nico-root-ca-secret` (cert-manager), not a
   standalone internal root.
3. **AppRole auth**, via the `nico` role and `nico-vault-policy` (grants
   `nicoca/issue/nico-cluster` and `nicoca/sign/nico-cluster`, plus
   `secrets/data/machines*`). `nico-api` picks up its `VAULT_ROLE_ID`/
   `VAULT_SECRET_ID` from the `nico-vault-approle-tokens` Secret that
   `make vault-init` populates.

If you're working against a site whose Vault predates this, just re-run
`make vault-init` — the "Configuring Vault" step runs unconditionally.

## Observing Progress

```bash
make machine-a-tron-status                              # managed hosts + state
```

Or the underlying CLI directly, for more detail (`nico-admin-cli` is
bundled in the `nico-api` pod; its default target doesn't exist here, so
the connection flags are mandatory):

```bash
CLI() {
  oc exec -n nico-system deploy/nico-api -- /opt/nico/nico-admin-cli \
    --api-url https://nico-api.nico-system.svc.cluster.local:1079 \
    --client-cert-path /run/secrets/spiffe.io/tls.crt \
    --client-key-path /run/secrets/spiffe.io/tls.key \
    --forge-root-ca-path /run/secrets/spiffe.io/ca.crt \
    "$@"
}

CLI managed-host show                        # all managed hosts + state
CLI --extended machine show <machine-id>     # full detail + state history
CLI --extended expected-machine show         # machines registered by machine-a-tron
CLI machine-interfaces show                  # MAC/IP allocations
```

(Define `CLI` as a function, not a variable — `CLI="oc exec ..."` followed
by `$CLI managed-host show` is prone to zsh parsing the whole thing as one
command name with embedded spaces.)

The admin web UI works too, mounted under `/admin` on the same mTLS port
(1079) as gRPC — not at bare paths, and not over plain `http://`. A client
cert is requested but not enforced (`bypass_rbac = true`), so a plain
`curl -sk` works from inside the cluster or via `oc port-forward
svc/nico-api -n nico-system 1079:1079`:

```
https://nico-api.nico-system.svc.cluster.local:1079/admin/managed-host.json
https://nico-api.nico-system.svc.cluster.local:1079/admin/machine/<id>/state-history
```

**What "done" looks like** for a NoDpu host: `STATE: READY`, clean state
history with no `Failed`/error entries, and `sku generate`/`redfish
bios-attrs`/`machine-validation on-demand start` all succeed against it. See
[Allocating a NoDpu Host to a Tenant](#allocating-a-nodpu-host-to-a-tenant)
to go further and assign it to a tenant instance.

Expected flow (`dpu_per_host_count = 0`):

```
DHCP Discovery → Site Explorer probes bmc-mock via Redfish
  → ManagedHost created (dpus: [])
    → HostInitializing/WaitingForPlatformConfiguration → PollingBiosSetup
      → SetBootOrder → WaitingForLockdown (skips DPU-down wait, no DPUs)
        → BomValidating/MatchingSku → Ready
```

Cold start typically takes 5–10 minutes end-to-end, almost entirely real
wait timers (not something to interrupt).

## Allocating a NoDpu Host to a Tenant

Once both hosts show `Ready`, they're zero-DPU machines with a materialized
`HostInband` interface (real IP from `[networks.hostinband]`, e.g.
`192.168.253.10`) — allocate them into a tenant via a **flat VPC**. `flat`
virtualization is specifically for zero-DPU/NIC-mode hosts: tenant instances
live directly on the underlay via `HostInband` segments, and NICo doesn't
drive the data plane (routing/ACLs between flat VPCs are the network
operator's responsibility).

`instance allocate`'s CLI machine-picker help text (and its `mellanox`-vendor
filtering) predates this — ignore it and use `--flat-vpc-id` with an explicit
`--machine-id`, which bypasses the picker entirely.

```bash
# 1. Create a flat VPC (top-level --cloud-unsafe-op is required for any
#    write that would normally be driven by the cloud REST API/tenant
#    control plane — we're going straight to Core, bypassing it).
CLI --cloud-unsafe-op=$USER vpc create \
  --name nodpu-tenant-vpc --org-id test-org --virtualization-type flat --extended
# → note the VPC ID from the output

# 2. Find the hostinband segment ID and attach it to the VPC.
CLI network-segment show   # find the "hostinband" row's Id
CLI --cloud-unsafe-op=$USER network-segment attach-vpc \
  --id <hostinband-segment-id> --vpc-id <vpc-id>

# 3. Allocate each Ready host onto the VPC. --os is required; a dummy
#    inline-iPXE definition is enough (no real Scout will boot it).
CLI --cloud-unsafe-op=$USER instance allocate \
  --machine-id <host-machine-id> \
  --flat-vpc-id <vpc-id> \
  --prefix-name eth0 \
  --tenant-org test-org \
  --os '{"variant":{"Ipxe":{"ipxe_script":"test-script"}},"phone_home_enabled":false,"run_provisioning_instructions_on_every_boot":false}'
```

`--os`'s JSON shape is the protobuf `InstanceOperatingSystemConfig` message
(snake_case fields, PascalCase oneof variant tag — `Ipxe`, `OsImageId`, or
`OperatingSystemId`), not documented in `--help`; the CLI's parse errors are
the fastest way to iterate on it if this shape ever drifts.

Expect `CLI managed-host show` to report `Assigned/Ready` and `CLI instance
show` to report `TenantState: Ready`, `ConfigsSynced: Synced`, with an
`IPAddresses` value from the `hostinband` prefix.

## Troubleshooting Reference

| Symptom | Cause | Fix |
|---|---|---|
| `No network segment defined for relay addresses: [x.x.x.x]` | No `[networks.*]` segment covers that relay IP | Add/fix a `[networks.<name>]` entry whose `prefix` contains it |
| `No domain configured, skipping initial network creation` | `initial_domain_name` unset | Set it |
| `Cannot create managed host for explored endpoint with no DPUs: ...disallowed by config` | `site_explorer.allow_zero_dpu_hosts` unset (defaults false) | Set `allow_zero_dpu_hosts = true` |
| Host stuck in `HostInitializing/Measuring { WaitingForMeasurements }` | `attestation_enabled = true` (default), no real Scout to send measurements | Set `attestation_enabled = false`, `tpm_required = false` |
| `Failed to generate client certificate: ... Vault ... 403/404/400` on `DiscoverMachine` | Vault PKI (`nicoca`) not enabled/misconfigured | See Vault Prerequisites |
| `Missing credential machines/bmc/site/root` | BMC credentials not bootstrapped | `make bootstrap-machine-a-tron` |
| Vault login returns bare `permission denied` (403) on any `nico-admin-cli credential` command | Kubernetes auth reviewer JWT stale/misconfigured (see Vault Prerequisites) — reproduce directly with `vault write auth/kubernetes/login role=nico-api jwt=<sa-token>` against `vault-0`, since Vault doesn't log auth failures by default | Confirm the `system:auth-delegator` ClusterRoleBinding targets SA `vault` (not a one-shot Job's SA), and that `token_reviewer_jwt` is unset in `auth/kubernetes/config` |
| Redfish GET returns 403 `Factory-default password must be changed` | `site-wide-root` password equals a vendor's factory-default password | Rotate `site-wide-root` to a distinct password |
| `Site explorer will not explore this endpoint to avoid lockout` | A prior bad-credential attempt got cached | `CLI site-explorer clear-error <ip>` (no port) |
| Host stuck in `WaitingForCleanup/HostCleanup`, retried every ~2s, zero progress | DPU-equipped host — needs a real Scout (limitation #1) | Switch that machine group to `dpu_per_host_count = 0` |
| A state is stuck 5+ min with no errors, then suddenly progresses | Real wait timers gate reprocessing | Just wait |
| Still stuck after 5+ min with nothing logged | Some "wait" states (`Measuring`, `WaitingForLockdown`) only get reprocessed on a `nico-api` restart, not by polling | `oc rollout restart deployment/nico-api -n nico-system` |
| After restarting machine-a-tron, DHCP fails with `Network segment mismatch for existing MAC address` | Stale `machine_interfaces`/`expected_machine` rows from a previous run | See Resetting the Simulation |
| `instance allocate` reports "No available machines" for a `Ready` host | Its machine-picker filters on a "mellanox"-vendor NIC (cosmetic CLI-side check, not a server-side restriction) | Use `--machine-id` + `--flat-vpc-id` instead of the picker — see [Allocating a NoDpu Host to a Tenant](#allocating-a-nodpu-host-to-a-tenant) |
| `discover_dhcp` fails with `... which is not of the expected type host_inband` | Host NIC's `ExpectedInterface` (auto-declared by machine-a-tron as of `v2.2.0-pr`) needs a `host_inband`-type segment, but none exists | Add `[networks.hostinband]` (config-file enum, `type = "hostinband"`, no underscore) matching `host_inband_dhcp_relay_address` in `mat.toml` |
| `discover_machine` fails with `selected interface and discovery source IP do not belong to the same host` (`PermissionDenied`), host stuck in `HostInitializing/WaitingForDiscovery` forever | machine-a-tron's simulated Scout calls from the pod's real IP, not the simulated `HostInband` IP; nico-api can't verify the two match | Set `allow_insecure_discovery = true` in `nicoApiSiteConfig` |
| `vpc create`/`network-segment attach-vpc`/`instance allocate` fails with `operation not allowed due to potential inconsistencies with cloud database` | These are normally cloud-REST-API-driven operations; nico-admin-cli refuses by default when going straight to Core | Add the top-level `--cloud-unsafe-op=<username>` flag (before the subcommand) |
| `instance allocate` fails with `argument InstanceConfig::os is missing` | `--os` is required, no default | Pass a JSON `InstanceOperatingSystemConfig` — see [Allocating a NoDpu Host to a Tenant](#allocating-a-nodpu-host-to-a-tenant) for a minimal dummy value |
| Redfish GET starts 401ing on a previously-`Ready` host after `machine-validation on-demand`/reboot | bmc-mock resets to factory-default credentials across a simulated reboot; nico-api's cached rotated credential no longer matches | `CLI site-explorer clear-error <ip>`; if it re-fails immediately, re-run `make bootstrap-machine-a-tron` |
| After a full reset + restart, a known MAC gets a straight 401 (not the "factory default" 403) on its first probe | nico-api stores a per-MAC BMC credential in Vault (`machines/bmc/<mac>/root`) on first successful rotation; machine-a-tron reuses the same deterministic MACs every restart, but its `emptyDir`-backed bmc-mock resets to factory-default each time, so the stale Vault entry no longer matches. Deleting `machine_interfaces`/`expected_machine`/`managed_host` does **not** clear this | `CLI credential delete-bmc --kind=bmc-root --mac-address <mac>` for every MAC before restarting — see Resetting the Simulation, step 4 |

## Resetting the Simulation

machine-a-tron's own state resets on pod restart (`persist_dir` is an
`emptyDir`), but `nico-api`'s database keeps every machine/interface/
expected-machine record from the previous run — restarting machine-a-tron
alone causes new DHCP requests to collide with those stale records. To
start clean:

```bash
CLI managed-host show                                   # note the Machine IDs (H rows) first
CLI machine force-delete --machine <host-machine-id>     # 1. force-delete every managed host

CLI machine-interfaces show                              # 2. delete orphaned interfaces
CLI machine-interfaces delete <interface-id>             #    (Associated Node ID empty = orphaned)

CLI --extended expected-machine show                     # 3. delete stale expected-machine entries
CLI expected-machine delete <bmc-mac-address>            #    (these accumulate across runs)

CLI credential delete-bmc --kind=bmc-root --mac-address <bmc-mac-address>  # 4. clear stale per-MAC
                                                                            #    Vault credential — easy
                                                                            #    to miss, see Troubleshooting

oc rollout restart deployment/machine-a-tron -n nico-system  # 5. fresh DHCP/MAC cycle
```

Then `make machine-a-tron-status` — expect a fresh `ManagedHost` per
configured host within 1–2 minutes, `Ready` within 5–10. The very first
Redfish probe of a freshly-registered endpoint hitting the
factory-default 403 once is normal; clear it with `CLI site-explorer
clear-error <ip>` if it doesn't resolve on its own within a minute.

## Also Watch For

- **Postgres disk usage**: the site's `nico-site-core-pg-instance1-*-pgdata`
  PVC (20Gi default) can fill with unarchived WAL if pgbackrest archiving
  isn't succeeding — heavy iteration (restarts, force-deletes, credential
  churn) grows this noticeably. Check with `oc exec
  nico-site-core-pg-instance1-<suffix>-0 -n nico-system -c
  pgbackrest -- df -h /pgdata`. If full, Postgres crash-loops with `could
  not write lock file "postmaster.pid": No space left on device` and every
  DB call hangs/times out.
