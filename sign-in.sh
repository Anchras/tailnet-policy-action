# Copyright 2026 Anchras BV
# SPDX-License-Identifier: Apache-2.0
# shellcheck shell=bash
# Sourced by the tailnet-policy action's test and apply steps:
# exports the trust credential for the anchras CLI in this step's shell
# only. Nothing goes to $GITHUB_ENV or to disk.
#
# In: CLIENT_ID + AUDIENCE (workload identity federation with the job's
# GitHub OIDC token), or CLIENT_SECRET (an OAuth client).

# Hosted origins serve RPCs under /api, while direct API servers use
# the origin root. Discover the RPC base without transmitting credentials.
# Keep the action's original server input for CLI distribution downloads.
api_base="${ANCHRAS_SERVER%/}"
api_probe_status="$(curl --proto '=https' --tlsv1.2 -sS -o /dev/null -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' --data '{}' \
  "$api_base/anchras.auth.v1.AuthService/GetCurrentUser")"
if [ "$api_probe_status" = 404 ]; then
  api_base="$api_base/api"
  api_probe_status="$(curl --proto '=https' --tlsv1.2 -sS -o /dev/null -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' --data '{}' \
    "$api_base/anchras.auth.v1.AuthService/GetCurrentUser")"
fi
case "$api_probe_status" in
  200|401|403) export ANCHRAS_SERVER="$api_base" ;;
  *) echo "::error::could not discover the Anchras API (HTTP $api_probe_status)"; exit 1 ;;
esac
unset api_base api_probe_status

if [ -n "${CLIENT_ID:-}" ]; then
  if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
    echo "::error::client-id needs the job's OIDC token: add 'permissions: id-token: write' to the job"
    exit 1
  fi
  oidc_url="$ACTIONS_ID_TOKEN_REQUEST_URL"
  if [ -n "${AUDIENCE:-}" ]; then
    oidc_url="$oidc_url&audience=$(jq -rn --arg a "$AUDIENCE" '$a|@uri')"
  fi
  ANCHRAS_ID_TOKEN="$(curl --proto '=https' -fsSL -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$oidc_url" | jq -r .value)"
  if [ -z "$ANCHRAS_ID_TOKEN" ] || [ "$ANCHRAS_ID_TOKEN" = null ]; then
    echo "::error::GitHub did not issue an OIDC token"
    exit 1
  fi
  echo "::add-mask::$ANCHRAS_ID_TOKEN"
  export ANCHRAS_OAUTH_CLIENT_ID="$CLIENT_ID" ANCHRAS_ID_TOKEN
  unset oidc_url
elif [ -n "${CLIENT_SECRET:-}" ]; then
  echo "::add-mask::$CLIENT_SECRET"
  export ANCHRAS_OAUTH_CLIENT_SECRET="$CLIENT_SECRET"
else
  echo "::error::set client-id (workload identity federation) or client-secret (OAuth client)"
  exit 1
fi
unset CLIENT_SECRET

