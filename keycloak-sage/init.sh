#!/bin/sh

REALM_LIST="sage"

# Base URL of the Keycloak server and bootstrap admin credentials.
# Defaults match the docker-compose setup; override via env in Kubernetes.
KC_BASE="${KEYCLOAK_BASE_URL:-http://keycloak:8080}"
ADMIN_USER="${KC_ADMIN_USER:-tempadmin}"
ADMIN_PASS="${KC_ADMIN_PASSWORD:-tempadmin}"

echo "Waiting for Keycloak to become ready..."
KEYCLOAK_URL="${KC_BASE}/realms/master/.well-known/openid-configuration"

# Loop until curl successfully connects and gets a 200 HTTP status code
until [ "$(curl -s -o /dev/null -w "%{http_code}" "$KEYCLOAK_URL")" -eq 200 ]; do
  printf '.'
  sleep 5
done

echo "\nKeycloak is up! Giving it a brief 2-second buffer for DB flush..."
sleep 2

echo "Short buffer for DB flush..."
sleep 5

echo "Getting Admin Token..."
TOKEN_RESPONSE=$(curl -s -X POST "${KC_BASE}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=${ADMIN_USER}" \
  -d "password=${ADMIN_PASS}" \
  -d "grant_type=password" \
  -d "client_id=admin-cli")

if [ $? -ne 0 ]; then
  echo "ERROR: Failed to get token"
  exit 1
fi

# Extract token
ACCTOK=$(echo "$TOKEN_RESPONSE" | sed 's/.*"access_token":"\([^"]*\)".*/\1/')

if [ -z "$ACCTOK" ]; then
  echo "ERROR: Could not extract access token"
  exit 1
fi

echo "Token obtained successfully."

echo "Configuring Member User Attribute..."
for REALM_NAME in $REALM_LIST; do
  echo ""
  echo "[${REALM_NAME}] Configuring..."

  # --- can select different namespaces ---
  case "$REALM_NAME" in
    sage)
      URN_NAMESPACE="urn:sage.example.org"
      ;;
    another)
      URN_NAMESPACE="urn:anothertest.test.example.org"
      ;;
    *)
      # Default fallback if realm is not listed above
      URN_NAMESPACE="urn%3Adefault.example.org"
      echo "Warning: No specific namespace found for '$REALM_NAME'. Using default."
      ;;
  esac

  echo "Using namespace: $URN_NAMESPACE"

  curl -s -X POST "${KC_BASE}/realms/${REALM_NAME}/agm/admin/member-user-attribute/configuration" \
    -H "Authorization: Bearer $ACCTOK" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "{\"userAttribute\": \"localEntitlements\", \"urnNamespace\": \"$URN_NAMESPACE\", \"signatureMessage\": \"RCIAM Support team\"}"

  if [ $? -eq 0 ]; then
    echo "✓ [${REALM_NAME}] Success"
  else
    echo "✗ [${REALM_NAME}] Failed"
  fi

  # Small delay between requests
  sleep 1
done
echo ""
echo "All steps completed successfully."
