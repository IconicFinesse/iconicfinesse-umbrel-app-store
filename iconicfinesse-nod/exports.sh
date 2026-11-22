# Nod secrets: generated once on first install, then read back from the
# app's data folder on every start. Nothing secret is in the package
# itself. Formats match upstream's setup.sh (auth token + database
# password are hex, the vault key is base64 for 32 bytes).

NOD_APP_DIR="${APP_DATA_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
NOD_SECRETS_FILE="${NOD_APP_DIR}/data/nod-secrets.env"

if [ ! -f "${NOD_SECRETS_FILE}" ]; then
  mkdir -p "${NOD_APP_DIR}/data"
  {
    echo "NOD_AUTH_TOKEN=$(openssl rand -hex 32)"
    echo "NOD_VAULT_KEY=$(openssl rand -base64 32)"
    echo "NOD_POSTGRES_PASSWORD=$(openssl rand -hex 24)"
  } > "${NOD_SECRETS_FILE}"
  chmod 600 "${NOD_SECRETS_FILE}"
fi

# shellcheck disable=SC1090
. "${NOD_SECRETS_FILE}"
export NOD_AUTH_TOKEN NOD_VAULT_KEY NOD_POSTGRES_PASSWORD

# Optional operator-seeded LLM provider key (never part of the package).
# Drop a file at data/nod-llm.env containing:
#   OPENAI_COMPATIBLE_API_KEY=<key>
NOD_LLM_FILE="${NOD_APP_DIR}/data/nod-llm.env"
if [ -f "${NOD_LLM_FILE}" ]; then
  # shellcheck disable=SC1090
  . "${NOD_LLM_FILE}"
  export OPENAI_COMPATIBLE_API_KEY
fi
