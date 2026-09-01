# NICo Cleanup Guide

## Quick Start

```bash
./cleanup.sh
```

Type `yes` when prompted. The script will completely remove all NICo components.

## What Gets Deleted

### Helm Releases
- `nico-flow` (site)
- `nico-rest-site-agent` (site)
- `nico` (site/Core)
- `nico-site-infra` (site)
- `nico-rest` (cloud)
- `nico-rest-infra` (cloud)
- `nvidia-infra-controller-prereqs`

### Database Clusters & Data
- ✅ **PostgreSQL clusters** (nico-cloud-pg, nico-site-pg)
- ✅ **All PVCs** (database volumes - this is the KEY fix!)
- ✅ Keycloak realm data (stored in PostgreSQL)

### Namespaces
- `nico-rest`
- `nico-system`
- `rhbk-operator`

### Cluster-Scoped Resources
- ClusterIssuers: `nico-bootstrap-issuer`, `nico-rest-ca-issuer`, `site-issuer`, `vault-nico-issuer`
- Certificates: `nico-root-ca`
- Secrets: `nico-root-ca-secret`, `nico-roots-secret`

### Operator Instances (CSVs)
- PostgreSQL operator instances
- RHBK operator instances
- Vault operator instances
- External Secrets operator instances

### What Does NOT Get Deleted
- ✅ **Operator Subscriptions** - kept so operators don't need to be reinstalled
- ✅ **cert-manager namespace** - kept for cert-manager operator
- ✅ Other cluster resources

## Smart Finalizer Handling

The script avoids "stuck in terminating" issues by:

### 1. Remove Finalizers BEFORE Deletion
```bash
# Remove PostgreSQL cluster finalizers first
oc patch postgrescluster -n nico-rest --type json \
  -p '[{"op":"remove","path":"/metadata/finalizers"}]'

# Then delete
oc delete postgrescluster --all -n nico-rest
```

### 2. Use `--wait=false` 
Prevents blocking on stuck deletions:
```bash
oc delete namespace nico-rest --wait=false
```

### 3. Graceful Wait with Timeout
Waits up to 2 minutes for clean termination:
```bash
for i in {1..24}; do
    if namespaces terminated; then break; fi
    sleep 5
done
```

### 4. Force Delete as Last Resort
Only used if graceful termination fails:
```bash
oc delete namespace nico-rest --grace-period=0 --force
```

## Execution Order (Prevents Deadlocks)

1. **Helm releases** - Clean uninstall while resources are still accessible
2. **PostgreSQL finalizers** - Prevent Crunchy operator from blocking deletion
3. **PostgreSQL clusters** - Delete before namespace
4. **PVC finalizers** - Prevent storage finalizers from blocking
5. **PVCs** - Delete before namespace
6. **Application CRDs** - Keycloak, Vault instances
7. **Namespaces** - Everything inside is already gone
8. **Forced cleanup** - Only if something is stuck
9. **Cluster resources** - ClusterIssuers, certs last
10. **Operator CSVs** - Remove operator pods but keep subscriptions

## Common Finalizer Culprits

| Resource | Finalizer | Why It Blocks | Solution |
|----------|-----------|---------------|----------|
| PostgresCluster | `postgres-operator.crunchydata.com/finalizer` | Operator tries to clean up volumes | Remove before delete |
| PVC | `kubernetes.io/pvc-protection` | Mounted by pods | Delete pods first or remove finalizer |
| Namespace | Various | Resources inside still exist | Delete resources first or patch |
| Keycloak | `keycloak.org/finalizer` | Operator cleanup | Delete instance before namespace |
| Vault | `vault.banzaicloud.com/finalizer` | Unseal keys cleanup | Delete instance before namespace |

## Verification After Cleanup

```bash
# Should return nothing
oc get namespace nico-rest nico-system rhbk-operator 2>/dev/null

# Should return nothing
oc get postgrescluster -A 2>/dev/null

# Should return nothing  
oc get pvc -n nico-rest -n nico-system -n rhbk-operator 2>/dev/null

# Should return nothing
oc get clusterissuer | grep nico

# Should still exist (kept for reuse)
oc get subscriptions -A | grep -E "cert-manager|postgresql|rhbk|external-secrets"
```

## Troubleshooting

### Namespace Stuck in Terminating
```bash
# Check what's blocking
oc get namespace nico-rest -o json | jq .status.conditions

# Force remove finalizers
oc patch namespace nico-rest --type json \
  -p '[{"op":"remove","path":"/metadata/finalizers"}]'
```

### PVC Stuck
```bash
# Check which pod is using it
oc describe pvc <pvc-name> -n <namespace>

# Force delete
oc patch pvc <pvc-name> -n <namespace> --type json \
  -p '[{"op":"remove","path":"/metadata/finalizers"}]'
```

### PostgreSQL Cluster Won't Delete
```bash
# Check operator logs
oc logs -n postgres-operator-system deployment/pgo

# Force cleanup
oc patch postgrescluster nico-cloud-pg -n nico-rest --type json \
  -p '[{"op":"remove","path":"/metadata/finalizers"}]'
oc delete postgrescluster nico-cloud-pg -n nico-rest --force --grace-period=0
```

## Safe to Re-run

The script is **idempotent** - you can run it multiple times safely. It uses:
- `--ignore-not-found` for cluster resources
- `|| true` to continue on errors
- Existence checks before operations

## What to Do After Cleanup

1. **Verify cleanup completed:**
   ```bash
   oc get namespace nico-rest nico-system rhbk-operator
   # Should show: Error from server (NotFound)
   ```

2. **Start fresh deployment:**
   ```bash
   make deploy-prereqs
   make deploy-cloud-infra
   make deploy-cloud
   ```

3. **All operators will reinstall automatically** from the subscriptions

## Why This Fixes Your Problem

**The KEY issue:** Your previous cleanup left PostgreSQL PVCs intact, so:
- Old Keycloak realm data survived
- New deployment tried to import realm
- Realm already existed → import skipped
- Client secret mismatch → authentication failed

**This script:** Deletes the PostgreSQL clusters AND their PVCs, wiping all database state including Keycloak realm data, so you start completely fresh.
