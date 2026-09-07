CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster \
  -o jsonpath='{.spec.domain}' 2>/dev/null)

if [ -z "$CLUSTER_DOMAIN" ]; then
  echo "Error: could not resolve cluster ingress domain. Is KUBECONFIG set and oc logged in?" >&2
  exit 1
fi

export KC_URL="https://keycloak-rhbk-operator.${CLUSTER_DOMAIN}"

# Fetch the authoritative ncx-service client secret from the Keycloak admin API.
# The K8s keycloak-client-secret can be stale after re-deploys, and the raw
# secret value often contains +/= which curl -d corrupts if not URL-encoded.
_ADMIN_USER=$(oc get secret keycloak-admin-secret -n rhbk-operator \
  -o jsonpath='{.data.username}' | base64 -d)
_ADMIN_PASS=$(oc get secret keycloak-admin-secret -n rhbk-operator \
  -o jsonpath='{.data.password}' | base64 -d)

_ADMIN_TOKEN=$(curl -sk -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
  --data-urlencode "grant_type=password" \
  --data-urlencode "client_id=admin-cli" \
  --data-urlencode "username=$_ADMIN_USER" \
  --data-urlencode "password=$_ADMIN_PASS" \
  | jq -r .access_token)

_CLIENT_UUID=$(curl -sk -H "Authorization: Bearer $_ADMIN_TOKEN" \
  "$KC_URL/admin/realms/nico/clients?clientId=ncx-service" | jq -r '.[0].id')

_CLIENT_SECRET=$(curl -sk -H "Authorization: Bearer $_ADMIN_TOKEN" \
  "$KC_URL/admin/realms/nico/clients/$_CLIENT_UUID" | jq -r .secret)

export TOKEN=$(curl -sk -X POST "$KC_URL/realms/nico/protocol/openid-connect/token" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=ncx-service" \
  --data-urlencode "client_secret=$_CLIENT_SECRET" \
  | jq -r .access_token)

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "Error: failed to acquire token" >&2
  exit 1
fi

echo "Token acquired:"
echo "$TOKEN"
