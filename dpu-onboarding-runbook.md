# DPU Onboarding Runbook

Working notes for manually onboarding a DPU (Data Processing Unit) into NICo.
Prerequisites: BMC IP address and password known upfront (no DHCP discovery).

## Environment

| Variable | Value |
|---|---|
| Kubeconfig | `nico3_kubeconfig_new` — set `export KUBECONFIG=./nico3_kubeconfig_new` (repo root) before running any `oc` command |
| DPU BMC IP | `10.6.136.214` |
| DPU BMC user | `root` |
| DPU BMC password | `4PJi-8D3k_14mS` |
| Host BMC IP | `10.6.136.15` |
| Host BMC user | `ADMIN` |
| Host BMC password | `0penBmc1` |
| Host BMC MAC | `7C:C2:55:86:CA:07` |
| Host serial number | `S900770X4511818` |
| Host Redfish system ID | `1` |
| Host architecture | ARM (aarch64) |

> **Two separate BMCs:** NICo treats the DPU BMC and the host motherboard BMC as independent
> Redfish endpoints. Both must be registered. The DPU BMC manages the BlueField card; the host
> BMC manages the server's power, boot order, and BIOS. NICo pairs them by matching the DPU
> serial number against the host BMC's PCIe inventory.
>
> **ARM host:** NICo supports ARM hosts — it serves `aarch64/scout.efi` via PXE (same scout
> agent as x86, just the ARM build). NICo distinguishes ARM hosts from ARM DPUs by checking
> the BMC board name: if it contains "bluefield" it's a DPU, otherwise it's a host.

---

## Step 1 — Read DPU System Info via Redfish

> **Network access:** These `curl` commands run directly from your workstation and require
> direct network access to the BMC IP. If the BMC is only reachable from inside the cluster,
> run them from a throwaway pod: `oc run bmc-probe --rm -it --restart=Never --image=registry.access.redhat.com/ubi9/ubi -- bash`

First, enumerate available system IDs (the ID is not always `1`):

```bash
curl -sk -u root:4PJi-8D3k_14mS https://10.6.136.214/redfish/v1/Systems | python3 -m json.tool
```

**Result:** System ID is `Bluefield` (NVIDIA BlueField DPU).

```bash
curl -sk -u root:4PJi-8D3k_14mS https://10.6.136.214/redfish/v1/Systems/Bluefield | python3 -m json.tool
```

**Result:**

| Field | Value |
|---|---|
| SerialNumber | `MT240230076V` |
| UUID | `6e596a0f-e1b0-ee11-8000-58a2e1678682` |
| Processor | ARMv8 |
| Health | OK / Enabled |

---

## Step 2 — Read Network Interface MACs

MAC addresses are required for NICo machine registration.

**Result:** Three interfaces: `eth0`, `eth1` (data plane), `oob0` (out-of-band management).

```bash
for iface in eth0 eth1 oob0; do
  echo "=== $iface ==="; curl -sk -u root:4PJi-8D3k_14mS \
    https://10.6.136.214/redfish/v1/Systems/Bluefield/EthernetInterfaces/$iface \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('MACAddress','n/a'), d.get('SpeedMbps','?'), 'Mbps', d.get('LinkStatus','?'))"
done
```

**Result:**

| Interface | MAC | Speed | Status | Role |
|---|---|---|---|---|
| eth0 | `02:ef:36:6e:d2:48` | 200 Gbps | LinkUp | Data plane (primary) |
| eth1 | `02:02:66:83:a8:7d` | — | NoLink | Data plane (not connected) |
| oob0 | `58:a2:e1:67:86:a6` | 1 Gbps | LinkUp | OOB management (`10.6.136.214`) |

---

## Step 3 — Seed BMC Credentials in Vault

`make vault-init` seeds the site-wide BMC default (`machines/bmc/site/root`, password `0penBmc`).
If a BMC has been pre-configured with a **non-factory password**, you must also seed a
per-machine entry so site-explorer uses the correct credential instead of the site-wide default.

Seed credentials for **both** the DPU BMC and the host BMC before NICo attempts to contact them.
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
BMC_MAC="58:a2:e1:67:86:a6"         # DPU oob0 MAC from Step 2
BMC_MAC_UPPER=$(echo "$BMC_MAC" | tr '[:lower:]' '[:upper:]')
BMC_PASSWORD="4PJi-8D3k_14mS"       # actual current password (replace as needed)

for MAC in "$BMC_MAC" "$BMC_MAC_UPPER"; do
  oc exec $VAULT_POD -n $VAULT_NS -- sh -c \
    "export VAULT_TOKEN=$VAULT_TOKEN VAULT_SKIP_VERIFY=true && \
     printf '{\"UsernamePassword\":{\"username\":\"root\",\"password\":\"$BMC_PASSWORD\"}}' \
     | vault kv put secrets/machines/bmc/$MAC/root -"
done
```

### 3b — Seed the host BMC credential

```bash
HOST_BMC_MAC="7C:C2:55:86:CA:07"    # from Step 5c Redfish probe (Manager/1/EthernetInterfaces/1)
HOST_BMC_MAC_UPPER=$(echo "$HOST_BMC_MAC" | tr '[:lower:]' '[:upper:]')
HOST_BMC_MAC_LOWER=$(echo "$HOST_BMC_MAC" | tr '[:upper:]' '[:lower:]')
HOST_BMC_PASSWORD="0penBmc1"

for MAC in "$HOST_BMC_MAC_UPPER" "$HOST_BMC_MAC_LOWER"; do
  oc exec $VAULT_POD -n $VAULT_NS -- sh -c \
    "export VAULT_TOKEN=$VAULT_TOKEN VAULT_SKIP_VERIFY=true && \
     printf '{\"UsernamePassword\":{\"username\":\"ADMIN\",\"password\":\"$HOST_BMC_PASSWORD\"}}' \
     | vault kv put secrets/machines/bmc/$MAC/root -"
done
```

> **Chicken-and-egg:** You need the host BMC MAC to seed the credential, but you may not
> know it until you probe the host BMC in Step 5c. If so, run Step 5c's Redfish probe first
> to get the MAC, then come back here to seed the credential before registering the
> expected-machine.

### Verify all entries

```bash
for MAC in "$BMC_MAC" "$BMC_MAC_UPPER" "$HOST_BMC_MAC" "$HOST_BMC_MAC_UPPER"; do
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
  -- curl -sk -u root:4PJi-8D3k_14mS \
  https://10.6.136.214/redfish/v1/Systems/Bluefield 2>/dev/null
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
  "SerialNumber": "MT240230076V",
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
> The BMC MAC is `oob0`: `58:a2:e1:67:86:a6`
>
> **Static IP caveat:** NICo typically discovers machines via DHCP (BMC sends DHCP request →
> NICo matches by MAC). If the BMC is configured with a static IP and won't send DHCP,
> discovery may not trigger automatically — confirm with the site-agent operator.

```bash
# BMC_MAC and BMC_PASSWORD set in Step 3; SITE_ID set in Step 4c above
curl -sk -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "$API_URL/v2/org/ncx/nico/expected-machine" \
  -d "$(jq -n \
    --arg siteId "$SITE_ID" \
    --arg bmcMacAddress "$BMC_MAC" \
    --arg bmcPassword "$BMC_PASSWORD" \
    '{siteId:$siteId,bmcIp:"10.6.136.214",bmcMacAddress:$bmcMacAddress,bmcUsername:"root",
      bmcPassword:$bmcPassword,chassisSerialNumber:"MT240230076V",name:"dpu-bf3-01",
      manufacturer:"NVIDIA",model:"BlueField-3"}')" \
  | jq .
```

**Result:** HTTP 201. Machine registered with UUID (format 81834a63-1e39-44f4-90a7-6a24e9c17ba6 ) .

---

## Step 5a — Set BMC IP on Expected Machine (static-IP BMCs only)

NICo normally discovers BMC addresses via DHCP (the BMC sends a DHCP request, NICo
matches it by MAC and learns the IP). When the BMC has a **static IP** and will never
send a DHCP request, NICo cannot discover it on its own — the `bmcIpAddress` field on
the expected-machine record stays `null` and no `explored_endpoint` is created.

Verify the field is missing:

```bash
curl -sk -H "Authorization: Bearer $TOKEN" \
  "$API_URL/v2/org/ncx/nico/expected-machine" | jq '.[].bmcIpAddress'
```

If `null`, patch the expected-machine with the static BMC IP:

```bash
EXPECTED_MACHINE_ID=<id from Step 4d>

curl -sk -X PATCH -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "$API_URL/v2/org/ncx/nico/expected-machine/$EXPECTED_MACHINE_ID" \
  -d '{"bmcIpAddress":"10.6.136.214"}' | jq .
```

After patching, NICo's site-explorer will create an `explored_endpoint` for this IP
and begin the preingestion cycle within a few minutes.

---

## Step 5b — Verify DPU Preingestion

After registration, NICo's site-explorer contacts the BMC via Redfish and runs the
preingestion cycle: BMC reset, NTP check, firmware check. This takes a few minutes.

Monitor the preingestion state in the forge DB:

```bash
SITE_PG_POD=$(oc get pods -n nico-system \
  -l postgres-operator.crunchydata.com/role=master \
  --no-headers -o custom-columns=NAME:.metadata.name | head -1)
NICO_PASS=$(oc get secret nico-site-pg-pguser-nico -n nico-system \
  -o jsonpath='{.data.password}' | base64 -d)

oc exec $SITE_PG_POD -n nico-system -c database -- \
  env PGPASSWORD="$NICO_PASS" psql -U nico -d nico -h 127.0.0.1 \
  -c "SELECT address, preingestion_state, exploration_requested FROM explored_endpoints WHERE address = '10.6.136.214';"
```

Expected progression:
1. `{"state": "initial"}` → `{"phase": "waitforbmc", "state": "initialbmcreset"}` — BMC reset in progress
2. → `{"phase": "waitforexplorerrefresh", "state": "initialbmcreset"}` — awaiting fresh probe
3. → `{"state": "complete"}` — DPU fully preingested

> **Note:** `machineId` on the expected-machine record stays `null` until the host is
> discovered and paired with the DPU (Step 5c/9). The forge `machines` table will also be
> empty until that point — this is **expected** for a static-IP DPU registration. Machine
> records are only created as a host+DPU pair. The host BMC must also be registered (Step 5c)
> before pairing can occur.

If `preingestion_state` is stuck at `complete` with no machine record (e.g. after a
site-pg crash), use the recovery target:

```bash
make reset-dpu-endpoint BMC_IP=10.6.136.214
```

Check `nico-bmc-proxy` logs if the BMC is not being reached:

```bash
oc logs -n nico-system \
  -l app.kubernetes.io/name=nico-bmc-proxy --tail=50
```

---

## Step 5c — Register the Host BMC

NICo requires the host's own motherboard BMC (separate from the DPU BMC) to power-control
the host, set boot order for PXE, and configure BIOS. Without it, NICo cannot progress
beyond DPU preingestion — no machine record will be created.

### Probe the host BMC via Redfish

First, verify the host BMC is reachable and enumerate system IDs:

```bash
oc run host-bmc-check --rm -it --restart=Never \
  --image=registry.access.redhat.com/ubi9/ubi -- bash -c \
  "curl -sk -u ADMIN:0penBmc1 https://10.6.136.15/redfish/v1/Systems | python3 -m json.tool"
```

Then read the host system info (replace `System.Embedded.1` with the actual system ID):

```bash
oc run host-bmc-info --rm -it --restart=Never \
  --image=registry.access.redhat.com/ubi9/ubi -- bash -c \
  "curl -sk -u ADMIN:0penBmc1 https://10.6.136.15/redfish/v1/Systems/<system-id> | python3 -m json.tool"
```

Note the host's **SerialNumber** — needed for registration.

To find the **host BMC MAC address**, query the Manager's Ethernet Interfaces (the BMC
network port, not the host's NICs):

```bash
oc run host-bmc-mac --rm -it --restart=Never \
  --image=registry.access.redhat.com/ubi9/ubi -- bash -c \
  "curl -sk -u ADMIN:0penBmc1 \
    https://10.6.136.15/redfish/v1/Managers/1/EthernetInterfaces/1 \
    | python3 -c \"import sys,json; d=json.load(sys.stdin); print('MAC:', d.get('MACAddress'), 'IP:', [a.get('Address') for a in d.get('IPv4Addresses',[])])\""
```

**Result:** MAC `7C:C2:55:86:CA:07`, IP `10.6.136.15`.

### Seed host BMC credential in Vault

If not already done in Step 3b or 3c, seed the host BMC credential now (you need the MAC
from the Redfish probe above). See Step 3b or 3c for the commands.

### Register the host as an expected-machine

The host BMC is a separate expected-machine record. NICo will pair it with the DPU
via serial number matching (the host BMC's PCIe inventory lists the BlueField DPU).

```bash
HOST_BMC_MAC="7C:C2:55:86:CA:07"
HOST_SERIAL="S900770X4511818"

curl -sk -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "$API_URL/v2/org/ncx/nico/expected-machine" \
  -d "$(jq -n \
    --arg siteId "$SITE_ID" \
    --arg bmcMacAddress "$HOST_BMC_MAC" \
    --arg serial "$HOST_SERIAL" \
    '{siteId:$siteId,bmcIpAddress:"10.6.136.15",bmcMacAddress:$bmcMacAddress,
      bmcUsername:"ADMIN",chassisSerialNumber:$serial,name:"arm-host-01"}')" \
  | jq .
```

> **Static IP:** If the host BMC also has a static IP (like the DPU BMC), include
> `bmcIpAddress` in the POST. If omitted, apply the Step 5a patch afterwards.

### Verify host BMC preingestion

Monitor the same way as Step 5b, but for the host BMC IP:

```bash
oc exec $SITE_PG_POD -n nico-system -c database -- \
  env PGPASSWORD="$NICO_PASS" psql -U nico -d nico -h 127.0.0.1 \
  -c "SELECT address, preingestion_state FROM explored_endpoints WHERE address = '10.6.136.15';"
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

Expected: `host_bmc_ip` = `10.6.136.15` with the DPU's BMC IP in `explored_dpus`.

---

## Step 6 — Verify DPU Data Plane Network Reachability

eth0 (`02:ef:36:6e:d2:48`, 200Gbps) is LinkUp but must be on a network segment reachable
from NICo's DHCP/PXE services (`nico-dhcp`, `nico-pxe` in `nico-system`).

Check that eth0 is on the management VLAN/subnet NICo expects for host PXE boot:

```bash
# Check NICo DHCP config for the expected subnet
oc get configmap -n nico-system \
  -l app.kubernetes.io/name=nico-dhcp -o yaml | grep -A5 subnet
```

A `subnet4` of `0.0.0.0/0` (catch-all) means the DHCP server will respond to any subnet —
no subnet mismatch to worry about.

### Verify L2 reachability from the cluster to eth0

The DHCP config alone doesn't prove the network path works. Confirm that the cluster
pods can actually reach the DPU data-plane interface at L2:

```bash
# 1. Check the DPU eth0 IP via Redfish (if assigned)
oc run net-check --rm -it --restart=Never \
  --image=registry.access.redhat.com/ubi9/ubi -- bash -c \
  "curl -sk -u root:4PJi-8D3k_14mS \
    https://10.6.136.214/redfish/v1/Systems/Bluefield/EthernetInterfaces/eth0 \
    | python3 -c \"import sys,json; d=json.load(sys.stdin); print('MAC:', d.get('MACAddress'), 'IPv4:', [a.get('Address') for a in d.get('IPv4Addresses',[])])\""

# 2. Verify the DHCP pod can see ARP/traffic from eth0's MAC (02:ef:36:6e:d2:48)
#    Check if NICo DHCP has received any requests from this MAC:
oc logs -n nico-system -l app.kubernetes.io/name=nico-dhcp --tail=200 \
  | grep -i "02:ef:36:6e:d2:48"

# 3. Verify the NICo DHCP and PXE services are listening
oc get svc -n nico-system | grep -E 'dhcp|pxe'
```

If the DHCP log shows no traffic from eth0's MAC, the DPU data plane is not on
a network segment reachable from the cluster — check VLAN tagging, physical cabling,
or bridge configuration on the host/switch side.

Without this reachability, the host cannot PXE boot through the DPU.

---

## Step 7 — Check Machine State and DPU OS

Once `machineId` is populated, check the machine record and its state:

```bash
MACHINE_ID=<machineId from step 5>

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
