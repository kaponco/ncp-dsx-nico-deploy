# DPU Onboarding Runbook

Working notes for manually onboarding a DPU (Data Processing Unit) into NICo.
Prerequisites: BMC IP address and password known upfront (no DHCP discovery).

---

## Step 0 — Network Prerequisites (must be done before Step 7)

NICo's automated provisioning requires **Layer 2 connectivity** between the DPU's data plane
ports and NICo's DHCP/PXE/DNS services running in the `nico-system` namespace. Without this,
two critical flows are blocked:

1. **DPU HTTP Boot** (Step 7): After NICo configures and reboots the DPU, the DPU must UEFI
   HTTP Boot via its data plane interface (eth0). It needs a DHCP response from NICo (not the
   lab DHCP) to get an IP and boot URI, then downloads the BFB image from NICo's PXE service.

2. **Host PXE Discovery** (Step 9): The host PXE boots **through the DPU's data plane** —
   the DPU acts as a network bridge. The host needs NICo's DHCP to get an IP and the
   `scout.efi` boot file. Same L2 path as above.

### What the lab/network team needs to configure

The DPU data plane ports (eth0/eth1, MACs from Step 2a) must be on a VLAN/subnet that
can reach the NICo DHCP and PXE services. There are two approaches:

**Option A — DHCP Relay (recommended for shared lab networks)**

Configure the lab switch to relay DHCP requests from the DPU data plane VLAN to the NICo
DHCP service ClusterIP:

```bash
# Get the NICo DHCP and PXE service ClusterIPs
oc get svc -n nico-system nico-dhcp nico-pxe nico-dns
```

The relay target is the DHCP service ClusterIP on UDP port 67. The OpenShift nodes must
be able to route the relayed traffic to the ClusterIP network.

**Option B — Dedicated VLAN with direct L2 access**

Place the DPU data plane ports and the OpenShift worker node(s) running NICo pods on the
same VLAN. The DHCP pod needs `hostNetwork: true` or a Multus macvlan network attachment
to bind directly to the node's interface on that VLAN.

### Required network paths

| From | To | Protocol | Purpose |
|---|---|---|---|
| DPU eth0 | NICo DHCP (`nico-dhcp` svc) | UDP 67/68 | IP assignment + boot URI |
| DPU eth0 | NICo PXE (`nico-pxe` svc) | TCP 8080 | BFB image download (HTTP Boot) |
| DPU eth0 | NICo DNS (`nico-dns` svc) | UDP/TCP 53 | Name resolution |
| Host NIC (via DPU bridge) | Same as above | Same | Host PXE discovery |

### Verification

After the network is configured, verify from a pod on the same network:

```bash
# Confirm NICo DHCP is listening (should show the service responding)
oc get svc -n nico-system nico-dhcp

# Check DHCP pod logs for socket bind success (no DHCPSRV_NO_SOCKETS_OPEN error)
oc logs -n nico-system -l app.kubernetes.io/name=nico-dhcp --tail=20 | grep -E "SOCKET|STARTED"
```

> **Without this network setup, NICo will configure and reboot the DPU (Steps 1–6 succeed)
> but the DPU will fall back to its existing OS and never download the NICo BFB. The machine
> state controller will stay stuck at `dpunotready.init` indefinitely.**

---

## Environment

| Variable | Value |
|---|---|
| Kubeconfig | `nico3_kubeconfig_new` — set `export KUBECONFIG=./nico3_kubeconfig_new` (repo root) before running any `oc` command |
| DPU BMC IP | `10.6.136.28` |
| DPU BMC user | `root` |
| DPU BMC password | `bluefield012` |
| DPU serial number | `MT2337XZ05A7` |
| DPU BMC Manager MAC | `a0:88:c2:75:91:8f` (use this for registration, not oob0) |
| Host BMC IP | `10.6.136.44` |
| Host BMC user | `root` |
| Host BMC password | `calvin` |
| Host BMC MAC | `c8:4b:d6:86:f3:a0` |
| Host serial number | `MXFC40029800IU` |
| Host Redfish system ID | `System.Embedded.1` |
| Host architecture | x86_64 (Dell PowerEdge R750) |

> **Two separate BMCs:** NICo treats the DPU BMC and the host motherboard BMC as independent
> Redfish endpoints. Both must be registered. The DPU BMC manages the BlueField card; the host
> BMC manages the server's power, boot order, and BIOS. NICo pairs them by matching the DPU
> serial number against the host BMC's PCIe inventory.
>
> **ARM host:** NICo supports ARM hosts — it serves `aarch64/scout.efi` via PXE (same scout
> agent as x86, just the ARM build). NICo distinguishes ARM hosts from ARM DPUs by checking
> the BMC board name: if it contains "bluefield" it's a DPU, otherwise it's a host.

---

## Step 1 — Probe Both BMCs via Redfish

> **Network access:** These `curl` commands run directly from your workstation and require
> direct network access to the BMC IP. If the BMC is only reachable from inside the cluster,
> run them from a throwaway pod: `oc run bmc-probe --rm -it --restart=Never --image=registry.access.redhat.com/ubi9/ubi -- bash`

### 1a — DPU BMC system info

Enumerate available system IDs (the ID is not always `1`):

```bash
curl -sk -u root:bluefield012 https://10.6.136.28/redfish/v1/Systems | jq '.Members[]."@odata.id"'
```

**Result:** System ID is `Bluefield`.

```bash
curl -sk -u root:bluefield012 https://10.6.136.28/redfish/v1/Systems/Bluefield | jq '{SerialNumber, UUID, Model, Status}'
```

**Result:**

| Field | Value |
|---|---|
| SerialNumber | `MT2337XZ05A7` |
| UUID | `00000000-0000-0000-0000-000000000000` |
| Model | BlueField-3 DPU |
| Health | OK / Enabled |

### 1b — Host BMC system info

```bash
curl -sk -u root:calvin https://10.6.136.44/redfish/v1/Systems | jq '.Members[]."@odata.id"'
```

Note the host system ID (e.g. `System.Embedded.1`, `1`, etc.) and use it below:

```bash
curl -sk -u root:calvin https://10.6.136.44/redfish/v1/Systems/System.Embedded.1 | jq '{SerialNumber, UUID, Model, Status}'
```

**Result:**

| Field | Value |
|---|---|
| SerialNumber | `MXFC40029800IU` |
| Model | Dell PowerEdge R750 |
| Health | OK / Enabled |

### 1c — Host BMC MAC address

Query the Manager's Ethernet Interfaces (the BMC network port, not the host's NICs):

```bash
curl -sk -u root:calvin https://10.6.136.44/redfish/v1/Managers/iDRAC.Embedded.1/EthernetInterfaces/NIC.1 \
  | jq '{MACAddress, IPv4Addresses: [.IPv4Addresses[].Address]}'
```

**Result:**

| Value | Result |
|---|---|
| Host BMC MAC | `c8:4b:d6:86:f3:a0` |
| Host BMC IP | `10.6.136.44` |

---

## Step 2 — Read DPU Network Interface MACs

MAC addresses are required for NICo machine registration.

### 2a — Data plane and OOB interfaces

```bash
for iface in eth0 eth1 oob0; do
  echo "=== $iface ==="
  curl -sk -u root:bluefield012 \
    https://10.6.136.28/redfish/v1/Systems/Bluefield/EthernetInterfaces/$iface \
    | jq '{MACAddress, SpeedMbps, LinkStatus}'
done
```

**Result:**

| Interface | MAC | Speed | Status | Role |
|---|---|---|---|---|
| eth0 | `02:de:1f:c2:c5:11` | 100 Gbps | LinkUp | Data plane (primary) |
| eth1 | `02:31:dd:95:f6:18` | 100 Gbps | LinkUp | Data plane |
| oob0 | `a0:88:c2:75:91:8e` | 1 Gbps | LinkUp | OOB management (`10.6.136.28`) |

### 2b — BMC Manager MAC (the MAC NICo uses)

> **Important:** The oob0 MAC (from Systems) and the BMC Manager MAC (from Managers)
> can differ by one byte on BlueField DPUs. NICo internally uses the **Manager MAC**
> for validation. Always use the Manager MAC for expected-machine registration and
> Vault credential seeding — not the oob0 MAC.

```bash
curl -sk -u root:bluefield012 \
  https://10.6.136.28/redfish/v1/Managers/Bluefield_BMC/EthernetInterfaces/eth0 \
  | jq '{MACAddress, LinkStatus}'
```

**Result:**

| Value | Result |
|---|---|
| BMC Manager MAC | `a0:88:c2:75:91:8f` |

Use this MAC (not oob0) for Steps 3 and 4.

---

## Step 3 — Seed BMC Credentials in Vault

`make vault-init` seeds the site-wide BMC default (`machines/bmc/site/root`, password `0penBmc`).
If a BMC has been pre-configured with a **non-factory password**, you must also seed a
per-machine entry so site-explorer uses the correct credential instead of the site-wide default.

Skip any BMC whose password is the factory default (`0penBmc`).

### Determine the Vault root token

```bash
export VAULT_NS=nico-system
export VAULT_POD=vault-0
VAULT_TOKEN=$(oc get secret vault-unseal-secret -n $VAULT_NS \
  -o jsonpath='{.data.root-token}' | base64 -d)
```

### 3a — Seed the DPU BMC credential

Site-explorer looks up `machines/bmc/{MAC}/root` first before falling back to the site-wide path.
The MAC must be in uppercase, colon-separated format. Seed both cases to be safe:

```bash
BMC_MAC="a0:88:c2:75:91:8f"         # DPU BMC Manager MAC from Step 2b
BMC_MAC_UPPER=$(echo "$BMC_MAC" | tr '[:lower:]' '[:upper:]')
BMC_PASSWORD="bluefield012"

for MAC in "$BMC_MAC" "$BMC_MAC_UPPER"; do
  oc exec $VAULT_POD -n $VAULT_NS -- sh -c \
    "export VAULT_TOKEN=$VAULT_TOKEN VAULT_SKIP_VERIFY=true && \
     printf '{\"UsernamePassword\":{\"username\":\"root\",\"password\":\"$BMC_PASSWORD\"}}' \
     | vault kv put secrets/machines/bmc/$MAC/root -"
done
```

### 3b — Seed the host BMC credential

Use the host BMC MAC from Step 1c:

```bash
HOST_BMC_MAC="c8:4b:d6:86:f3:a0"   # host BMC MAC from Step 1c
HOST_BMC_MAC_UPPER=$(echo "$HOST_BMC_MAC" | tr '[:lower:]' '[:upper:]')
HOST_BMC_MAC_LOWER=$(echo "$HOST_BMC_MAC" | tr '[:upper:]' '[:lower:]')
HOST_BMC_PASSWORD="calvin"

for MAC in "$HOST_BMC_MAC_UPPER" "$HOST_BMC_MAC_LOWER"; do
  oc exec $VAULT_POD -n $VAULT_NS -- sh -c \
    "export VAULT_TOKEN=$VAULT_TOKEN VAULT_SKIP_VERIFY=true && \
     printf '{\"UsernamePassword\":{\"username\":\"root\",\"password\":\"$HOST_BMC_PASSWORD\"}}' \
     | vault kv put secrets/machines/bmc/$MAC/root -"
done
```

### Verify all entries

```bash
for MAC in "$BMC_MAC" "$BMC_MAC_UPPER" "$HOST_BMC_MAC_UPPER" "$HOST_BMC_MAC_LOWER"; do
  echo "=== $MAC ==="
  oc exec $VAULT_POD -n $VAULT_NS -- sh -c \
    "export VAULT_TOKEN=$VAULT_TOKEN VAULT_SKIP_VERIFY=true && \
     vault kv get secrets/machines/bmc/$MAC/root"
done
```

> **Note:** Once NICo successfully ingests the machine it will rotate the BMC credentials
> automatically and update these Vault paths. The per-machine paths take precedence over the
> site-wide `machines/bmc/site/root` path.

---

## Step 4 — Register the DPU in NICo

### 4a — Verify BMC Connectivity

Before registering, confirm the BMC is reachable from the cluster. Run from a throwaway pod:

```bash
echo "Next call is using a password to the specific BMC in the lab - which may be obsolete..."
oc delete pod bmc-check --ignore-not-found=true 2>/dev/null
oc run bmc-check --restart=Never \
  --image=registry.access.redhat.com/ubi9/ubi \
  -- curl -sk -u root:bluefield012 \
  https://10.6.136.28/redfish/v1/Systems/Bluefield 2>/dev/null
oc wait pod/bmc-check --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s
BMC_RESP=$(oc logs pod/bmc-check)
oc delete pod bmc-check --ignore-not-found=true 2>/dev/null

echo "$BMC_RESP" | jq '{SerialNumber, State: .Status.State, Health: .Status.Health}'

echo "$BMC_RESP" | jq -e '
  .Status.State == "Enabled" and .Status.Health == "OK"
' > /dev/null \
  && echo "BMC OK — proceed" \
  || echo "BMC NOT OK — do not proceed"
```

Expected output:
```json
{
  "SerialNumber": "<serial-from-step-1>",
  "State": "Enabled",
  "Health": "OK"
}
BMC OK — proceed
```

Connection refused, timeout, or `BMC NOT OK` means the BMC is not reachable or unhealthy — do not proceed.

---

### 4b — Acquire API token

Same flow as `validate-machines.sh`.

```bash
DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
KC_URL="https://keycloak-rhbk-operator.$DOMAIN"
API_URL="https://nico-rest-api-nico-rest.$DOMAIN"

_ADMIN_USER=$(oc get secret keycloak-admin-secret -n rhbk-operator -o jsonpath='{.data.username}' | base64 -d)
_ADMIN_PASS=$(oc get secret keycloak-admin-secret -n rhbk-operator -o jsonpath='{.data.password}' | base64 -d)
_ADMIN_TOKEN=$(curl -sk -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli \
  -d "username=$_ADMIN_USER" -d "password=$_ADMIN_PASS" | jq -r .access_token)
_CLIENT_UUID=$(curl -sk -H "Authorization: Bearer $_ADMIN_TOKEN" \
  "$KC_URL/admin/realms/nico/clients?clientId=ncx-service" | jq -r '.[0].id')
CLIENT_SECRET=$(curl -sk -H "Authorization: Bearer $_ADMIN_TOKEN" \
  "$KC_URL/admin/realms/nico/clients/$_CLIENT_UUID" | jq -r .secret)
TOKEN=$(curl -sk -X POST "$KC_URL/realms/nico/protocol/openid-connect/token" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=ncx-service" \
  --data-urlencode "client_secret=$CLIENT_SECRET" \
  | jq -r .access_token)
echo "Token: ${TOKEN:0:20}..."
```

### 4c — Find the target site ID

```bash
curl -sk -H "Authorization: Bearer $TOKEN" \
  "$API_URL/v2/org/ncx/nico/site" | jq -r '.[] | "\(.id)  \(.name)"'
```

Pick the site UUID this DPU belongs to and set:

```bash
SITE_ID=<site-id-from-above>
```

### 4d — Pre-register the machine (expected-machine)

> **Note:** There is no `POST /machine` endpoint. Machines are auto-discovered by NICo.
> The correct flow is: create an **expected-machine** record (keyed on the BMC MAC address),
> then NICo matches it when it discovers the DPU at the site.
>
> The BMC MAC is `oob0` — use the MAC from Step 2
>
> **Static IP caveat:** NICo typically discovers machines via DHCP (BMC sends DHCP request →
> NICo matches by MAC). If the BMC is configured with a static IP and won't send DHCP,
> discovery may not trigger automatically — confirm with the site-agent operator.

```bash
# BMC_MAC and BMC_PASSWORD set in Step 3; SITE_ID set in Step 4c above
# DPU_SERIAL from Step 1
DPU_SERIAL="MT2337XZ05A7"
curl -sk -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "$API_URL/v2/org/ncx/nico/expected-machine" \
  -d "$(jq -n \
    --arg siteId "$SITE_ID" \
    --arg bmcMacAddress "$BMC_MAC" \
    --arg bmcPassword "$BMC_PASSWORD" \
    --arg serial "$DPU_SERIAL" \
    '{siteId:$siteId,bmcIpAddress:"10.6.136.28",bmcMacAddress:$bmcMacAddress,bmcUsername:"root",
      bmcPassword:$bmcPassword,chassisSerialNumber:$serial,name:"dpu-bf3-01",
      manufacturer:"NVIDIA",model:"BlueField-3"}')" \
  | jq .
```

**Result:** Expect HTTP 201 with a UUID. Save it as `EXPECTED_MACHINE_ID`.

---

## Step 5a — Verify DPU Preingestion

After registration, NICo's site-explorer contacts the BMC via Redfish and runs the
preingestion cycle: BMC reset, NTP check, firmware check. This takes a few minutes.

Monitor (repeat until completed) the preingestion state in the forge DB:

```bash
SITE_PG_POD=$(oc get pods -n nico-system \
  -l postgres-operator.crunchydata.com/role=master \
  --no-headers -o custom-columns=NAME:.metadata.name | head -1)
NICO_PASS=$(oc get secret nico-site-pg-pguser-nico -n nico-system \
  -o jsonpath='{.data.password}' | base64 -d)

oc exec $SITE_PG_POD -n nico-system -c database -- \
  env PGPASSWORD="$NICO_PASS" psql -U nico -d nico -h 127.0.0.1 \
  -c "SELECT address, preingestion_state, exploration_requested FROM explored_endpoints WHERE address = '10.6.136.28';"
```

Expected progression:
1. `{"state": "initial"}` → `{"phase": "waitforbmc", "state": "initialbmcreset"}` — BMC reset in progress
2. → `{"phase": "waitforexplorerrefresh", "state": "initialbmcreset"}` — awaiting fresh probe
3. → `{"state": "complete"}` — DPU fully preingested

> **Note:** `machineId` on the expected-machine record stays `null` until the host is
> discovered and paired with the DPU (Step 5b/9). The forge `machines` table will also be
> empty until that point — this is **expected**. Machine records are only created as a
> host+DPU pair. The host BMC must also be registered (Step 5b) before pairing can occur.

If `preingestion_state` is stuck at `complete` with no machine record (e.g. after a
site-pg crash), use the recovery target:

```bash
make reset-dpu-endpoint BMC_IP=10.6.136.28
```

Check `nico-bmc-proxy` logs if the BMC is not being reached:

```bash
oc logs -n nico-system \
  -l app.kubernetes.io/name=nico-bmc-proxy --tail=50
```

---

## Step 5b — Register the Host BMC

NICo requires the host's own motherboard BMC (separate from the DPU BMC) to power-control
the host, set boot order for PXE, and configure BIOS. Without it, NICo cannot progress
beyond DPU preingestion — no machine record will be created.

The host BMC was already probed in Step 1b/1c and its credential seeded in Step 3b.

### Register the host as an expected-machine

The host BMC is a separate expected-machine record. NICo will pair it with the DPU
via serial number matching (the host BMC's PCIe inventory lists the BlueField DPU).

Use the MAC and serial from Step 1b/1c:

```bash
HOST_BMC_MAC="c8:4b:d6:86:f3:a0"
HOST_SERIAL="MXFC40029800IU"

curl -sk -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "$API_URL/v2/org/ncx/nico/expected-machine" \
  -d "$(jq -n \
    --arg siteId "$SITE_ID" \
    --arg bmcMacAddress "$HOST_BMC_MAC" \
    --arg serial "$HOST_SERIAL" \
    '{siteId:$siteId,bmcIpAddress:"10.6.136.44",bmcMacAddress:$bmcMacAddress,
      bmcUsername:"root",chassisSerialNumber:$serial,name:"host-01"}')" \
  | jq .
```

### Verify host BMC preingestion

Monitor (repeat until completed) the same way as Step 5a, but for the host BMC IP:

```bash
oc exec $SITE_PG_POD -n nico-system -c database -- \
  env PGPASSWORD="$NICO_PASS" psql -U nico -d nico -h 127.0.0.1 \
  -c "SELECT address, preingestion_state FROM explored_endpoints WHERE address = '10.6.136.44';"
```

Wait for `{"state": "complete"}`. Once both the DPU and host BMC are preingested,
NICo will pair them and create a machine record.

### Verify DPU-host pairing

After both BMCs are preingested, check that NICo paired them:

```bash
oc exec $SITE_PG_POD -n nico-system -c database -- \
  env PGPASSWORD="$NICO_PASS" psql -U nico -d nico -h 127.0.0.1 \
  -c "SELECT host_bmc_ip, explored_dpus FROM explored_managed_hosts;"
```

Expected: `host_bmc_ip` = `10.6.136.44` with the DPU's BMC IP in `explored_dpus`.

---

## Step 6 — Verify DPU Data Plane Network Reachability

The DPU eth0 interface (data plane primary, from Step 2) must be on a network segment reachable
from NICo's DHCP/PXE services (`nico-dhcp`, `nico-pxe` in `nico-system`).

Check that eth0 is on the management VLAN/subnet NICo expects for host PXE boot:

```bash
# Check NICo DHCP config for the expected subnet
oc get configmap -n nico-system \
  -l app.kubernetes.io/name=nico-dhcp -o yaml | grep -A5 subnet
```

A `subnet4` of `0.0.0.0/0` (catch-all) means the DHCP server will respond to any subnet —
no subnet mismatch to worry about.

### Verify DHCP and PXE services are listening

```bash
oc get svc -n nico-system | grep -E 'dhcp|pxe'
```

Both services must be present. DHCP traffic from eth0 won't appear until NICo
configures the DPU's network mode (after Step 7).

---

## Step 7 — Check Machine State and DPU OS

Once `machineId` is populated, check the machine record and its state:

```bash
MACHINE_ID=<machineId from the list above>

curl -sk -H "Authorization: Bearer $TOKEN" \
  "$API_URL/v2/org/ncx/nico/machine/$MACHINE_ID" | jq '{state: .state, dpuStatus: .dpuStatus}'
```

The DPU may need BF-OS re-flash if it is in a stale or unconfigured state.
NICo handles this automatically once the machine is recognized — monitor state transitions.

---

## Step 8 — Define Host Lifecycle Profile

Before provisioning the host, an OS image and lifecycle profile must exist in NICo.
For ARM (aarch64) hosts, ensure the OS image is built for the ARM architecture.

```bash
# List available OS images
curl -sk -H "Authorization: Bearer $TOKEN" \
  "$API_URL/v2/org/ncx/nico/os-image" | jq '.[] | {id, name}'

# List available lifecycle profiles
curl -sk -H "Authorization: Bearer $TOKEN" \
  "$API_URL/v2/org/ncx/nico/lifecycle-profile" | jq '.[] | {id, name}'
```

If none exist, an OS image must be uploaded and a lifecycle profile created before Step 9.

---

## Step 9 — Wait for Host Discovery

After the DPU is configured by NICo, it acts as the management interface for the host.
NICo will power-cycle the host (via the host BMC) and attempt to discover it via PXE/DHCP
through the DPU. For ARM hosts, NICo serves `aarch64/scout.efi` which enumerates the
host's hardware via SMBIOS and registers it with NICo Core.

Monitor the machine list for a second entry (the host):

```bash
curl -sk -H "Authorization: Bearer $TOKEN" \
  "$API_URL/v2/org/ncx/nico/machine" | jq '.[] | {id, name, state, type}'
```

---

## Step 10 — Trigger Host OS Provisioning

Once the host machine record exists and a lifecycle profile is defined, assign the profile
and trigger provisioning:

```bash
HOST_MACHINE_ID=<host machine id from step 9>
LIFECYCLE_PROFILE_ID=<profile id from step 8>

curl -sk -X PATCH -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "$API_URL/v2/org/ncx/nico/machine/$HOST_MACHINE_ID" \
  -d "{\"hostLifecycleProfileId\": \"$LIFECYCLE_PROFILE_ID\"}" | jq .
```

Monitor state transitions until the host reaches a `Ready` state.
