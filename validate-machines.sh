#!/usr/bin/env bash
# Validate site and machine count in NICo via the REST API
# Run: bash validate-machines.sh
set -euo pipefail

# Step 1 — cluster domain
echo "Cluster: $(oc whoami --show-server 2>/dev/null || { echo 'ERROR: no cluster configured (run oc login first)'; exit 1; })"
DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
echo "Domain: $DOMAIN"

KC_URL="https://keycloak-rhbk-operator.$DOMAIN"
API_URL="https://nico-rest-api-nico-rest.$DOMAIN"

# Step 2 — Keycloak admin token
_ADMIN_USER=$(oc get secret keycloak-admin-secret -n rhbk-operator -o jsonpath='{.data.username}' | base64 -d)
_ADMIN_PASS=$(oc get secret keycloak-admin-secret -n rhbk-operator -o jsonpath='{.data.password}' | base64 -d)

_ADMIN_TOKEN=$(curl -sk -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli \
  -d "username=$_ADMIN_USER" -d "password=$_ADMIN_PASS" | jq -r .access_token)

# Step 3 — ncx-service client secret
_CLIENT_UUID=$(curl -sk -H "Authorization: Bearer $_ADMIN_TOKEN" \
  "$KC_URL/admin/realms/nico/clients?clientId=ncx-service" | jq -r '.[0].id')

CLIENT_SECRET=$(curl -sk -H "Authorization: Bearer $_ADMIN_TOKEN" \
  "$KC_URL/admin/realms/nico/clients/$_CLIENT_UUID" | jq -r .secret)

echo "Client secret acquired."

# Step 4 — get bearer token
TOKEN=$(curl -sk -X POST "$KC_URL/realms/nico/protocol/openid-connect/token" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=ncx-service" \
  --data-urlencode "client_secret=$CLIENT_SECRET" \
  | jq -r .access_token)

[ -n "$TOKEN" ] && [ "$TOKEN" != null ] || { echo "ERROR: failed to get bearer token"; exit 1; }
echo "Bearer token acquired."

# Step 5 — list sites
echo ""
echo "--- Sites ---"
SITES=$(curl -sk -H "Authorization: Bearer $TOKEN" \
  "$API_URL/v2/org/ncx/nico/site")
echo "$SITES" | jq -r '.[] | "\(.name) (\(.status))"' 2>/dev/null \
  || echo "$SITES" | jq -r '.items[] | "\(.name) (\(.status))"' 2>/dev/null

# Step 6 — list machines per site
echo ""
echo "--- Machines per site ---"
echo "$SITES" | jq -c '.[]' | while read -r site; do
  SITE_ID=$(echo "$site" | jq -r '.id')
  SITE_NAME=$(echo "$site" | jq -r '.name')
  MACHINES=$(curl -sk -H "Authorization: Bearer $TOKEN" \
    "$API_URL/v2/org/ncx/nico/machine?siteId=$SITE_ID")
  COUNT=$(echo "$MACHINES" | jq 'if type == "array" then length else (.items | length) end' 2>/dev/null || echo "?")
  echo "Site: $SITE_NAME ($SITE_ID) — $COUNT machine(s)"
  echo "$MACHINES" | jq -r 'if type == "array" then .[] else .items[] end | "  \(.name) [\(.lifecycleStatus)]"' 2>/dev/null || true
done
