#!/usr/bin/env bash
set -euo pipefail

resource_group="${RESOURCE_GROUP:-rg-eleven-gptlive-poc}"
environment_name="${CONTAINERAPPS_ENVIRONMENT:-cae-eleven-gptlive-poc}"
app_name="${LITEGRAPH_APP_NAME:-litegraph-memory-poc}"
voice_app_name="${VOICE_APP_NAME:-eleven-gptlive-poc}"
location="${AZURE_LOCATION:-southcentralus}"
environment_storage_name="${ENV_STORAGE_NAME:-litegraphpocdata}"
storage_share="${STORAGE_SHARE_NAME:-litegraph}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${STORAGE_ACCOUNT_NAME:-}" ]]; then
  echo "Set STORAGE_ACCOUNT_NAME to a globally unique Azure Storage account name." >&2
  exit 2
fi

for command_name in az jq openssl sed; do
  command -v "${command_name}" >/dev/null || {
    echo "Missing required command: ${command_name}" >&2
    exit 2
  }
done

# This legacy bootstrap creates container-local SQLite and rotates credentials.
# Never use it to update an app containing memories.
if az containerapp show --name "${app_name}" --resource-group "${resource_group}" \
  --output none 2>/dev/null; then
  echo "Refusing legacy SQLite bootstrap on an existing app. Use the durable-storage migration runbook." >&2
  exit 2
fi
if [[ "${ALLOW_EPHEMERAL_SYNTHETIC_POC:-}" != "yes" ]]; then
  echo "This legacy bootstrap is ephemeral. Set ALLOW_EPHEMERAL_SYNTHETIC_POC=yes only for disposable synthetic-data tests." >&2
  exit 2
fi

work_dir="$(mktemp -d)"
cleanup() {
  rm -rf "${work_dir}"
}
trap cleanup EXIT

litegraph_admin_token="$(openssl rand -hex 32)"
mcp_edge_token="$(openssl rand -hex 32)"
encryption_key="$(openssl rand -hex 32)"
encryption_iv="$(openssl rand -hex 16)"

environment_id="$(az containerapp env show \
  --name "${environment_name}" \
  --resource-group "${resource_group}" \
  --query id -o tsv)"

jq \
  --arg admin_token "${litegraph_admin_token}" \
  --arg encryption_key "${encryption_key}" \
  --arg encryption_iv "${encryption_iv}" \
  '.Rest.Hostname = "*"
   | .LiteGraph.AdminBearerToken = $admin_token
   | .LiteGraph.GraphRepositoryFilename = "/tmp/litegraph.db"
   | .LiteGraph.Database.Type = "Sqlite"
   | .LiteGraph.Database.Filename = "/tmp/litegraph.db"
   | .LiteGraph.Database.InMemory = false
   | .LiteGraph.InMemory = false
   | .Encryption.Key = $encryption_key
   | .Encryption.Iv = $encryption_iv
   | .Storage.BackupsDirectory = "/tmp/backups/"' \
  "${script_dir}/litegraph.base.json" >"${work_dir}/litegraph.json"

cp "${script_dir}/Caddyfile" "${work_dir}/Caddyfile"

az storage account create \
  --name "${STORAGE_ACCOUNT_NAME}" \
  --resource-group "${resource_group}" \
  --location "${location}" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --output none

storage_key="$(az storage account keys list \
  --account-name "${STORAGE_ACCOUNT_NAME}" \
  --resource-group "${resource_group}" \
  --query '[0].value' -o tsv)"

az storage share-rm create \
  --resource-group "${resource_group}" \
  --storage-account "${STORAGE_ACCOUNT_NAME}" \
  --name "${storage_share}" \
  --quota 5 \
  --output none

for config_file in litegraph.json Caddyfile; do
  az storage file upload \
    --account-name "${STORAGE_ACCOUNT_NAME}" \
    --account-key "${storage_key}" \
    --share-name "${storage_share}" \
    --source "${work_dir}/${config_file}" \
    --output none
done

az containerapp env storage set \
  --name "${environment_name}" \
  --resource-group "${resource_group}" \
  --storage-name "${environment_storage_name}" \
  --azure-file-account-name "${STORAGE_ACCOUNT_NAME}" \
  --azure-file-account-key "${storage_key}" \
  --azure-file-share-name "${storage_share}" \
  --access-mode ReadWrite \
  --output none

sed \
  -e "s|__LOCATION__|${location}|g" \
  -e "s|__APP_NAME__|${app_name}|g" \
  -e "s|__ENVIRONMENT_ID__|${environment_id}|g" \
  -e "s|__ENV_STORAGE_NAME__|${environment_storage_name}|g" \
  -e "s|__LITEGRAPH_ADMIN_TOKEN__|${litegraph_admin_token}|g" \
  -e "s|__MCP_EDGE_TOKEN__|${mcp_edge_token}|g" \
  "${script_dir}/containerapp.yaml.template" >"${work_dir}/containerapp.yaml"

if az containerapp show \
  --name "${app_name}" \
  --resource-group "${resource_group}" \
  --output none 2>/dev/null; then
  az containerapp update \
    --name "${app_name}" \
    --resource-group "${resource_group}" \
    --yaml "${work_dir}/containerapp.yaml" \
    --output none
else
  az containerapp create \
    --name "${app_name}" \
    --resource-group "${resource_group}" \
    --yaml "${work_dir}/containerapp.yaml" \
    --output none
fi

fqdn="$(az containerapp show \
  --name "${app_name}" \
  --resource-group "${resource_group}" \
  --query properties.configuration.ingress.fqdn -o tsv)"

# Store the complete outbound Authorization header as an unused secret on the
# existing voice canary. This does not change its revision, routing, or env.
az containerapp secret set \
  --name "${voice_app_name}" \
  --resource-group "${resource_group}" \
  --secrets "mcp-authorization=Bearer ${mcp_edge_token}" \
  --output none

cat <<EOF
LiteGraph POC deployed.
Health: https://${fqdn}/health
MCP URL: https://${fqdn}/mcp
Authorization was stored on ${voice_app_name} as secret mcp-authorization.
The working voice revision and environment variables were not changed.
EOF
