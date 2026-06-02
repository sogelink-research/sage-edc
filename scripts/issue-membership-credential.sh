#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
TSG_BASE_URL="https://authority.tsg.beta.geodan.nl"
TSG_OAUTH_URL="https://sso-bridge.authority.tsg.beta.geodan.nl"
TSG_CLIENT_ID="wallet"
TSG_CLIENT_SECRET="wallet"

CONNECTOR_DID="did:web:sogelink.edc.beta.geodan.nl"
CREDENTIAL_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
MEMBERSHIP_SINCE="2026-01-01T00:00:00Z"
MEMBERSHIP_TYPE="FullMember"

CONTEXT_URL="https://storage.googleapis.com/sogelink-research-public/projects/cg/context-membership-credential.json"
KEY_ID="key-0"

# ---------------------------------------------------------------------------
# Fetch bearer token
# ---------------------------------------------------------------------------
echo "Fetching OAuth token from ${TSG_OAUTH_URL}/api/oauth/token ..."

TOKEN_RESPONSE=$(curl -sf -X POST \
	"${TSG_OAUTH_URL}/api/oauth/token" \
	-H "Content-Type: application/x-www-form-urlencoded" \
	--data-urlencode "grant_type=client_credentials" \
	--data-urlencode "client_id=${TSG_CLIENT_ID}" \
	--data-urlencode "client_secret=${TSG_CLIENT_SECRET}" \
	--data-urlencode "scope=SCOPE")

ACCESS_TOKEN=$(echo "${TOKEN_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
echo "Token acquired."

# ---------------------------------------------------------------------------
# Issue MembershipCredential
# ---------------------------------------------------------------------------
echo "Issuing MembershipCredential for ${CONNECTOR_DID} ..."

RESPONSE=$(curl -sf -X POST \
	"${TSG_BASE_URL}/api/management/credentials" \
	-H "Content-Type: application/json" \
	-H "Accept: application/json" \
	-H "Authorization: Bearer ${ACCESS_TOKEN}" \
	-d "{
  \"context\": [
    \"${CONTEXT_URL}\"
  ],
  \"type\": [
    \"MembershipCredential\"
  ],
  \"id\": \"${CREDENTIAL_ID}\",
  \"proofType\": \"ldp\",
  \"keyId\": \"${KEY_ID}\",
  \"credentialSubject\": {
    \"id\": \"${CONNECTOR_DID}\",
    \"membership\": {
      \"membershipType\": \"${MEMBERSHIP_TYPE}\",
      \"since\": \"${MEMBERSHIP_SINCE}\"
    }
  },
  \"revocable\": true
}")

echo "Response:"
echo "${RESPONSE}" | python3 -m json.tool 2>/dev/null || echo "${RESPONSE}"
