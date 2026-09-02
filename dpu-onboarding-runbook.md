# DPU Onboarding Runbook

Working notes for manually onboarding a DPU (Data Processing Unit) into NICo.
Prerequisites: BMC IP address and password known upfront (no DHCP discovery).

## Environment

| Variable | Value |
|---|---|
| Kubeconfig | `nico3_kubeconfig_new` |
| BMC IP | `10.6.136.214` |
| BMC user | `root` |
| BMC password | `4PJi-8D3k_14mS` |

---

## Step 1 — Verify BMC Accessibility via Redfish

Run from a pod inside the cluster to confirm the BMC is reachable from the cluster network.

```bash
# Quick connectivity check — Redfish service root
KUBECONFIG=~/nico3_kubeconfig_new oc run bmc-test --rm -it --restart=Never \
  --image=registry.access.redhat.com/ubi9/ubi \
  -- bash -c "curl -sk -u root:4PJi-8D3k_14mS https://10.6.136.214/redfish/v1/ \
     | python3 -m json.tool"


Expected: HTTP 200 with JSON. Connection refused or timeout = BMC not reachable from cluster.

**Result:** BMC reachable. `Vendor: Nvidia`, `RedfishVersion: 1.17.0`, `UUID: eb571820-146e-40ee-b22d-49152ed6f672`

---

---

## Step 2 — Read DPU System Info via Redfish

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

## Step 3 — Read Network Interface MACs

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

## Step 4 — Register the DPU in NICo

### 4a — Acquire API token

Same flow as `validate-machines.sh`. Set `KUBECONFIG` first:

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

### 4b — Find the target site ID

```bash
curl -sk -H "Authorization: Bearer $TOKEN" \
  "$API_URL/v2/org/ncx/nico/site" | jq -r '.[] | "\(.id)  \(.name)"'
```

Pick the site this DPU belongs to and set:

```bash
SITE_ID=<site-id-from-above>
```

### 4c — Pre-register the machine (expected-machine)

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
curl -sk -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "$API_URL/v2/org/ncx/nico/expected-machine" \
  -d '{
    "siteId": "b8aad3f5-5ab9-4752-9795-200ac20e4aa4",
    "bmcMacAddress": "58:a2:e1:67:86:a6",
    "defaultBmcUsername": "root",
    "defaultBmcPassword": "4PJi-8D3k_14mS",
    "chassisSerialNumber": "MT240230076V"
  }' | jq .
```

**Result:** 504 timeout. Root cause: version mismatch between rest-api and site-agent.

- `nico-rest-api` digest: `sha256:0504aafe...` (newer — has `CreateExpectedMachine` handler)
- `nico-rest-site-agent` digest: `sha256:c3ef6c7b...` (older — missing `CreateExpectedMachine` handler)

The Temporal workflow is dispatched to the site task queue but the site-agent never picks it up.

**Fix:** Redeploy site-agent with a matching image version before retrying.
