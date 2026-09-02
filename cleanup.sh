#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -e

if ! oc whoami --show-server >/dev/null 2>&1; then
    echo "ERROR: no cluster configured (run oc login first)"
    exit 1
fi
echo "Cluster: $(oc whoami --show-server)"

echo "=========================================="
echo "NICo Complete Cleanup Script"
echo "=========================================="
echo ""
echo "This will delete:"
echo "  - All NICo Helm releases"
echo "  - PostgreSQL clusters and PVCs"
echo "  - Namespaces: nico-rest, rhbk-operator, nico-system"
echo "  - ClusterIssuers and certificates"
echo "  - Operator CSVs (subscriptions remain for reuse)"
echo ""
read -p "Continue? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo "==> Step 1: Delete Helm releases"
helm uninstall -n nico-system nico-flow 2>/dev/null || echo "  nico-flow not found"
helm uninstall -n nico-system nico-rest-site-agent 2>/dev/null || echo "  nico-rest-site-agent not found"
helm uninstall -n nico-system nico 2>/dev/null || echo "  nico (site) not found"
helm uninstall -n nico-system nico-site-infra 2>/dev/null || echo "  nico-site-infra not found"
helm uninstall -n nico-rest nico-rest 2>/dev/null || echo "  nico-rest not found"
helm uninstall -n nico-rest nico-rest-infra 2>/dev/null || echo "  nico-rest-infra not found"
helm uninstall -n default nvidia-infra-controller-prereqs 2>/dev/null || echo "  nvidia-infra-controller-prereqs not found"

echo ""
echo "==> Step 2: Remove finalizers from PostgreSQL clusters"
for ns in nico-rest nico-system; do
    for pg in $(oc get postgrescluster -n $ns -o name 2>/dev/null); do
        echo "  Removing finalizers from $pg in $ns"
        oc patch $pg -n $ns --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
    done
done

echo ""
echo "==> Step 3: Delete PostgreSQL clusters"
oc delete postgrescluster --all -n nico-rest --wait=false 2>/dev/null || echo "  No PostgreSQL clusters in nico-rest"
oc delete postgrescluster --all -n nico-system --wait=false 2>/dev/null || echo "  No PostgreSQL clusters in nico-system"

echo ""
echo "==> Step 4: Remove finalizers from PVCs"
for ns in nico-rest nico-system rhbk-operator; do
    for pvc in $(oc get pvc -n $ns -o name 2>/dev/null); do
        echo "  Removing finalizers from $pvc in $ns"
        oc patch $pvc -n $ns --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
    done
done

echo ""
echo "==> Step 5: Delete PVCs"
oc delete pvc --all -n nico-rest --wait=false 2>/dev/null || echo "  No PVCs in nico-rest"
oc delete pvc --all -n nico-system --wait=false 2>/dev/null || echo "  No PVCs in nico-system"
oc delete pvc --all -n rhbk-operator --wait=false 2>/dev/null || echo "  No PVCs in rhbk-operator"

echo ""
echo "==> Step 6: Delete Keycloak resources"
oc delete keycloak --all -n rhbk-operator --wait=false 2>/dev/null || echo "  No Keycloak instances"
oc delete keycloakrealmimport --all -n rhbk-operator --wait=false 2>/dev/null || echo "  No KeycloakRealmImports"

echo ""
echo "==> Step 7: Delete Vault resources"
oc delete vault --all -n nico-system --wait=false 2>/dev/null || echo "  No Vault instances"

echo ""
echo "==> Step 8: Delete namespaces"
oc delete namespace nico-rest --wait=false 2>/dev/null || echo "  nico-rest namespace not found"
oc delete namespace nico-system --wait=false 2>/dev/null || echo "  nico-system namespace not found"
oc delete namespace rhbk-operator --wait=false 2>/dev/null || echo "  rhbk-operator namespace not found"

echo ""
echo "==> Step 9: Wait for namespaces to terminate (max 2 minutes)"
for i in {1..24}; do
    REMAINING=$(oc get ns nico-rest nico-system rhbk-operator --no-headers 2>/dev/null | wc -l)
    if [ "$REMAINING" -eq 0 ]; then
        echo "  ✓ All namespaces terminated"
        break
    fi
    echo "  Waiting... ($REMAINING namespaces remaining)"
    sleep 5
done

echo ""
echo "==> Step 10: Force delete stuck namespaces (if any)"
for ns in nico-rest nico-system rhbk-operator; do
    if oc get namespace $ns >/dev/null 2>&1; then
        echo "  Force removing finalizers from $ns namespace"
        oc patch namespace $ns --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
        oc delete namespace $ns --grace-period=0 --force 2>/dev/null || true
    fi
done

echo ""
echo "==> Step 11: Delete ClusterIssuers"
oc delete clusterissuer nico-bootstrap-issuer --ignore-not-found 2>/dev/null || true
oc delete clusterissuer nico-rest-ca-issuer --ignore-not-found 2>/dev/null || true
oc delete clusterissuer site-issuer --ignore-not-found 2>/dev/null || true
oc delete clusterissuer vault-nico-issuer --ignore-not-found 2>/dev/null || true

echo ""
echo "==> Step 12: Delete cert-manager resources"
oc delete certificate nico-root-ca -n cert-manager --ignore-not-found 2>/dev/null || true
oc delete secret nico-root-ca-secret -n cert-manager --ignore-not-found 2>/dev/null || true
oc delete secret nico-roots-secret -n cert-manager --ignore-not-found 2>/dev/null || true

echo ""
echo "==> Step 13: Delete operator CSVs (keep subscriptions for reuse)"
echo "  Note: This removes operator instances but keeps subscriptions"
for csv in $(oc get csv -A -o jsonpath='{.items[?(@.metadata.name=~"postgres|rhbk|vault|external-secrets")].metadata.name}' 2>/dev/null | tr ' ' '\n' | sort -u); do
    for ns in $(oc get csv -A -o json | jq -r ".items[] | select(.metadata.name==\"$csv\") | .metadata.namespace"); do
        echo "  Deleting CSV $csv in $ns"
        oc delete csv $csv -n $ns --ignore-not-found 2>/dev/null || true
    done
done

echo ""
echo "==> Step 14: Clean up local files"
rm -f .keycloak-client-secret
rm -f fix-deployment.sh update-keycloak-secret.sh add-org-to-token.sh add-org-mapper.sh
rm -f DEPLOYMENT_STATUS.md

echo ""
echo "=========================================="
echo "✅ Cleanup Complete!"
echo "=========================================="
echo ""
echo "Remaining subscriptions (will be reused):"
oc get subscriptions -A 2>/dev/null | grep -E "cert-manager|postgresql|rhbk|external-secrets" || echo "  None found"
echo ""
echo "You can now run a fresh deployment:"
echo "  make deploy-prereqs"
echo "  make deploy-cloud-infra"
echo "  make deploy-cloud"
echo ""
