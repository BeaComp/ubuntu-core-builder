# shellcheck shell=bash
# ══════════════════════════════════════════════════════════════════
#  common.sh — funções partilhadas do pipeline (logging, .env, gpg)
#  Este ficheiro é "sourced" pelo pipeline.sh; não é executável.
# ══════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Caminhos ───────────────────────────────────────────────────────
WORKSPACE="${WORKSPACE:-/workspace}"
CONFIG_DIR="$WORKSPACE/config"
ENV_FILE="$WORKSPACE/.env"
CRED_DIR="$WORKSPACE/.credentials"
CRED_FILE="$CRED_DIR/snapcraft-store.txt"
BUILD_DIR="$WORKSPACE/build"
OUTPUT_DIR="$WORKSPACE/output"
LOG_DIR="$WORKSPACE/logs"
GADGET_DIR="$WORKSPACE/pi-gadget"
GADGET_YAML="$GADGET_DIR/gadget.yaml"
NETWORK_FILE="$WORKSPACE/network.yaml"
SSH_KEYS_FILE="$CONFIG_DIR/ssh-authorized-keys"

MODEL_TEMPLATE="$CONFIG_DIR/model.template.json"
SYSTEM_USER_TEMPLATE="$CONFIG_DIR/system-user.template.json"

# GNUPGHOME aponta para o keyring que o snapd usa para "snap sign".
# SNAP_GNUPG_HOME é obrigatório: o snapd ignora GNUPGHOME/HOME e, sob
# sudo, resolve o keyring pelo utilizador real (SUDO_USER) — sem isto,
# "snap keys"/"snap sign" e o gpg usariam keyrings diferentes em CI.
export PATH="$PATH:/snap/bin"
export GNUPGHOME="${GNUPGHOME:-$HOME/.snap/gnupg}"
export SNAP_GNUPG_HOME="$GNUPGHOME"

# ── Logging ────────────────────────────────────────────────────────
if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BLUE=$'\033[34m'
else
    C_RESET=""; C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""
fi

_ts()   { date '+%H:%M:%S'; }
info()  { echo "${C_BLUE}[$(_ts)] ℹ ${C_RESET} $*"; }
ok()    { echo "${C_GREEN}[$(_ts)] ✔ ${C_RESET} $*"; }
warn()  { echo "${C_YELLOW}[$(_ts)] ⚠ ${C_RESET} $*" >&2; }
err()   { echo "${C_RED}[$(_ts)] ✖ ${C_RESET} $*" >&2; }
die()   { err "$@"; exit 1; }

stage() {
    echo ""
    echo "${C_BOLD}──────────────────────────────────────────────────${C_RESET}"
    echo "${C_BOLD}  $*${C_RESET}"
    echo "${C_BOLD}──────────────────────────────────────────────────${C_RESET}"
}

# Reporta a linha onde um comando falhou (complementa o set -e)
trap 'err "Falha na linha $LINENO: comando \"$BASH_COMMAND\" (código $?)"' ERR

is_interactive() { [ -t 0 ]; }

# ── Configuração (.env) ────────────────────────────────────────────
load_env() {
    [ -f "$ENV_FILE" ] || die "Ficheiro .env não encontrado. Copia o exemplo: cp $CONFIG_DIR/.env.example $ENV_FILE"

    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a

    # Obrigatórios
    : "${KEY_NAME:?KEY_NAME em falta no .env}"

    # Opcionais com valores por omissão
    KEY_PASSPHRASE="${KEY_PASSPHRASE:-}"
    MODEL_NAME="${MODEL_NAME:-rpi5-gateway}"
    ARCHITECTURE="${ARCHITECTURE:-arm64}"
    BASE="${BASE:-core24}"
    GRADE="${GRADE:-dangerous}"
    SYSTEM_USER_EMAIL="${SYSTEM_USER_EMAIL:-}"
    SYSTEM_USER_USERNAME="${SYSTEM_USER_USERNAME:-}"
    SYSTEM_USER_FULLNAME="${SYSTEM_USER_FULLNAME:-$SYSTEM_USER_USERNAME}"
    SYSTEM_USER_VALID_YEARS="${SYSTEM_USER_VALID_YEARS:-10}"
    COMPRESS_IMAGE="${COMPRESS_IMAGE:-false}"

    if [ -z "$KEY_PASSPHRASE" ]; then
        warn "KEY_PASSPHRASE vazia — a chave será criada/usada SEM passphrase (adequado a CI, menos seguro)."
    fi
}

# ── GPG ────────────────────────────────────────────────────────────
setup_gpg() {
    mkdir -p "$GNUPGHOME"
    chmod 700 "$GNUPGHOME"
    # allow-preset-passphrase permite injetar a passphrase no gpg-agent
    # para que o "snap sign" corra sem interação
    cat > "$GNUPGHOME/gpg-agent.conf" <<EOF
allow-preset-passphrase
default-cache-ttl 86400
max-cache-ttl 86400
EOF
    gpgconf --kill gpg-agent 2>/dev/null || true
    gpg-connect-agent --quiet /bye 2>/dev/null || true
}

# Chave local existe no keyring do snap?
key_exists() {
    snap keys 2>/dev/null | awk -v k="$KEY_NAME" 'NR>1 && $1==k {found=1} END {exit !found}'
}

# Injeta a passphrase no gpg-agent (uma vez por sessão)
preset_passphrase() {
    [ -n "$KEY_PASSPHRASE" ] || return 0

    local preset_bin="/usr/lib/gnupg/gpg-preset-passphrase"
    if [ ! -x "$preset_bin" ]; then
        warn "gpg-preset-passphrase não encontrado — o snap sign poderá pedir a passphrase interativamente."
        return 0
    fi

    local grips
    grips=$(gpg --list-secret-keys --with-keygrip --with-colons "$KEY_NAME" 2>/dev/null \
            | awk -F: '/^grp/ {print $10}')
    [ -n "$grips" ] || die "Não encontrei keygrips para a chave '$KEY_NAME' em $GNUPGHOME."

    local grip
    for grip in $grips; do
        printf '%s' "$KEY_PASSPHRASE" | "$preset_bin" --preset "$grip"
    done
    ok "Passphrase carregada no gpg-agent (assinatura não-interativa ativa)."
}

# ── Autenticação na Snap Store ─────────────────────────────────────
# Exporta SNAPCRAFT_STORE_CREDENTIALS e define DEVELOPER_ID.
# Devolve 1 se não há credenciais válidas.
load_store_credentials() {
    [ -f "$CRED_FILE" ] || return 1
    SNAPCRAFT_STORE_CREDENTIALS=$(cat "$CRED_FILE")
    export SNAPCRAFT_STORE_CREDENTIALS

    local whoami_out
    if ! whoami_out=$(snapcraft whoami 2>/dev/null); then
        warn "Credenciais em $CRED_FILE inválidas ou expiradas."
        return 1
    fi

    # snapcraft >= 7 imprime "id: ..."; versões antigas "developer-id: ..."
    DEVELOPER_ID=$(echo "$whoami_out" | awk -F': *' '$1=="id" || $1=="developer-id" {print $2; exit}')
    [ -n "${DEVELOPER_ID:-}" ] || die "Não consegui extrair o developer-id de 'snapcraft whoami'."
    export DEVELOPER_ID
    return 0
}

# ── Limpeza global ─────────────────────────────────────────────────
# Se o build for interrompido a meio da injeção de rede no gadget,
# repõe o gadget.yaml original para não sujar o repositório do gadget.
cleanup_on_exit() {
    if [ -f "$GADGET_YAML.orig" ]; then
        mv -f "$GADGET_YAML.orig" "$GADGET_YAML"
    fi
}
trap cleanup_on_exit EXIT
