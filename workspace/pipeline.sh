#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════
#  pipeline.sh — Pipeline de criação de imagens Ubuntu Core
#
#  Autocomissionamento e gestão remota segura para IoT (Mestrado)
#
#  Subcomandos:
#    setup    Configuração inicial (login na Store, criação e registo
#             da chave). Interativo, corre UMA vez. Suporta 2FA.
#    build    Build completo, 100% não-interativo:
#             render das assertions → assinatura → gadget → imagem.
#    doctor   Diagnóstico do ambiente (dependências, auth, chave).
#    clean    Remove artefactos de build (não toca em credenciais).
#    all      setup (se necessário) + build.
#
#  Uso:  pipeline.sh <setup|build|doctor|clean|all> [--rebuild-gadget]
# ══════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

REBUILD_GADGET="${REBUILD_GADGET:-0}"

# ══════════════════════════════════════════════════════════════════
#  Dependências
# ══════════════════════════════════════════════════════════════════
ensure_deps() {
    local missing=0
    local tool
    for tool in jq yq gpg xz; do
        command -v "$tool" &>/dev/null || { err "Falta a ferramenta '$tool' (devia vir no Dockerfile)."; missing=1; }
    done
    [ "$missing" -eq 0 ] || die "Reconstrói o container: docker compose up -d --build"

    # snapcraft e ubuntu-image são snaps — instalação em runtime (1ª vez)
    if ! command -v snapcraft &>/dev/null; then
        info "A instalar snapcraft (primeira execução)..."
        snap install snapcraft --classic
    fi
    if ! command -v ubuntu-image &>/dev/null; then
        info "A instalar ubuntu-image (primeira execução)..."
        snap install ubuntu-image --classic
    fi
}

# ══════════════════════════════════════════════════════════════════
#  Autenticação na Snap Store (segura: sem passwords no .env)
# ══════════════════════════════════════════════════════════════════
ensure_store_auth() {
    if load_store_credentials; then
        ok "Autenticado na Snap Store como developer-id: $DEVELOPER_ID"
        return 0
    fi

    if ! is_interactive; then
        die "Sem credenciais válidas da Snap Store. Corre primeiro: pipeline.sh setup (interativo)"
    fi

    info "Login no Ubuntu One (o browser/terminal vai pedir email, password e 2FA se ativo)..."
    mkdir -p "$CRED_DIR" && chmod 700 "$CRED_DIR"
    snapcraft export-login "$CRED_FILE"
    chmod 600 "$CRED_FILE"

    load_store_credentials || die "Login falhou — não consegui validar as credenciais exportadas."
    ok "Token guardado em $CRED_FILE (600). Autenticado como developer-id: $DEVELOPER_ID"
}

# ══════════════════════════════════════════════════════════════════
#  Chave de assinatura (criação não-interativa + registo na Canonical)
# ══════════════════════════════════════════════════════════════════
ensure_signing_key() {
    setup_gpg

    if key_exists; then
        ok "Chave '$KEY_NAME' já existe no keyring local."
    else
        info "A criar a chave '$KEY_NAME' (RSA 4096, sem interação)..."
        local batch_file
        batch_file=$(mktemp)
        {
            echo "Key-Type: RSA"
            echo "Key-Length: 4096"
            echo "Name-Real: $KEY_NAME"
            echo "Expire-Date: 0"
            if [ -n "$KEY_PASSPHRASE" ]; then
                echo "Passphrase: $KEY_PASSPHRASE"
            else
                echo "%no-protection"
            fi
            echo "%commit"
        } > "$batch_file"
        gpg --batch --gen-key "$batch_file"
        rm -f "$batch_file"

        key_exists || die "A chave foi gerada mas o snapd não a reconhece ('snap keys')."
        ok "Chave '$KEY_NAME' criada."
    fi

    # Registo na Canonical (necessário para a cadeia de confiança --chain)
    if snapcraft list-keys 2>/dev/null | awk -v k="$KEY_NAME" '$1=="*" && $2==k {found=1} END {exit !found}'; then
        ok "Chave '$KEY_NAME' já está registada na tua conta Ubuntu One."
    else
        info "A registar a chave '$KEY_NAME' na Canonical..."
        if snapcraft register-key "$KEY_NAME"; then
            ok "Chave registada com sucesso."
        else
            # snapcraft devolve erro se a chave já estiver registada — tolera
            warn "register-key falhou. Se a mensagem acima disser que já está registada, ignora."
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════
#  Render das assertions (templates → JSON final, sem edição manual)
# ══════════════════════════════════════════════════════════════════
render_assertions() {
    stage "1/4 · Render das assertions (model + system-user)"
    mkdir -p "$BUILD_DIR"

    [ -f "$MODEL_TEMPLATE" ]       || die "Template não encontrado: $MODEL_TEMPLATE"
    [ -f "$SYSTEM_USER_TEMPLATE" ] || die "Template não encontrado: $SYSTEM_USER_TEMPLATE"
    [ -n "$SYSTEM_USER_EMAIL" ]    || die "SYSTEM_USER_EMAIL em falta no .env"
    [ -n "$SYSTEM_USER_USERNAME" ] || die "SYSTEM_USER_USERNAME em falta no .env"

    local now until
    now=$(date -u '+%Y-%m-%dT%H:%M:%S+00:00')
    until=$(date -u -d "+${SYSTEM_USER_VALID_YEARS} years" '+%Y-%m-%dT%H:%M:%S+00:00')

    # model.json — o developer-id vem do 'snapcraft whoami', nunca à mão
    jq --arg id    "$DEVELOPER_ID" \
       --arg ts    "$now" \
       --arg model "$MODEL_NAME" \
       --arg arch  "$ARCHITECTURE" \
       --arg base  "$BASE" \
       --arg grade "$GRADE" \
       '."authority-id" = $id
      | ."brand-id"     = $id
      | .timestamp      = $ts
      | .model          = $model
      | .architecture   = $arch
      | .base           = $base
      | .grade          = $grade' \
       "$MODEL_TEMPLATE" > "$BUILD_DIR/model.json"

    # system-user.json — chaves SSH lidas de config/ssh-authorized-keys
    [ -f "$SSH_KEYS_FILE" ] || die "Ficheiro de chaves SSH não encontrado: $SSH_KEYS_FILE (copia o .example e cola a tua chave pública)"
    local ssh_keys_json
    ssh_keys_json=$(grep -vE '^\s*(#|$)' "$SSH_KEYS_FILE" | jq -R . | jq -s .)
    [ "$(echo "$ssh_keys_json" | jq 'length')" -gt 0 ] \
        || die "Nenhuma chave SSH em $SSH_KEYS_FILE — sem ela não há acesso ao dispositivo!"

    jq --arg id       "$DEVELOPER_ID" \
       --arg email    "$SYSTEM_USER_EMAIL" \
       --arg username "$SYSTEM_USER_USERNAME" \
       --arg fullname "$SYSTEM_USER_FULLNAME" \
       --arg since    "$now" \
       --arg until    "$until" \
       --arg model    "$MODEL_NAME" \
       --argjson keys "$ssh_keys_json" \
       '."authority-id" = $id
      | ."brand-id"     = $id
      | .email          = $email
      | .username       = $username
      | .name           = $fullname
      | .since          = $since
      | .until          = $until
      | .models         = [$model]
      | ."ssh-keys"     = $keys' \
       "$SYSTEM_USER_TEMPLATE" > "$BUILD_DIR/system-user.json"

    jq empty "$BUILD_DIR/model.json" "$BUILD_DIR/system-user.json"
    ok "Assertions geradas em $BUILD_DIR/ (developer-id: $DEVELOPER_ID)"
}

# ══════════════════════════════════════════════════════════════════
#  Assinatura
# ══════════════════════════════════════════════════════════════════
sign_assertions() {
    stage "2/4 · Assinatura com a chave '$KEY_NAME'"
    preset_passphrase

    snap sign -k "$KEY_NAME" "$BUILD_DIR/model.json" > "$BUILD_DIR/model.model"
    ok "model.model assinado."

    # --chain embute account + account-key: obrigatório para o
    # auto-import do system-user no primeiro arranque do dispositivo
    snap sign -k "$KEY_NAME" "$BUILD_DIR/system-user.json" --chain > "$BUILD_DIR/system-user.assert"
    ok "system-user.assert assinado (com cadeia de confiança)."
}

# ══════════════════════════════════════════════════════════════════
#  Gadget (com injeção opcional de rede e cache inteligente)
# ══════════════════════════════════════════════════════════════════
build_gadget() {
    stage "3/4 · Gadget snap (pi-gadget)"
    [ -d "$GADGET_DIR" ] || die "Diretório do gadget não encontrado: $GADGET_DIR"

    local gadget_out="$BUILD_DIR/gadget.snap"

    # Cache: só reconstrói se as fontes mudaram ou se for forçado
    if [ -f "$gadget_out" ] && [ "$REBUILD_GADGET" != "1" ]; then
        if [ -z "$(find "$GADGET_DIR" -newer "$gadget_out" -not -path '*/.git/*' -type f -print -quit)" ]; then
            ok "Gadget sem alterações — a reutilizar $gadget_out (usa --rebuild-gadget para forçar)."
            return 0
        fi
    fi

    # Injeção de rede: mexe no gadget.yaml de forma reversível (trap repõe)
    if [ ! -f "$NETWORK_FILE" ]; then
        info "Sem network.yaml — imagem sem rede pré-configurada (console-conf no 1º arranque)."
    elif grep -q 'SEU_WIFI\|SUA_SENHA' "$NETWORK_FILE"; then
        warn "network.yaml ainda tem valores de exemplo — injeção de rede IGNORADA."
    elif [ "$(yq eval '.network | type' "$NETWORK_FILE" 2>/dev/null)" != "!!map" ]; then
        # Ficheiro vazio, só comentários ou sem a chave 'network:' de topo
        # produziria netplan=null e o snap pack rejeitaria o gadget
        warn "network.yaml vazio ou sem a chave 'network:' — injeção de rede IGNORADA."
    else
        info "A injetar configuração netplan no gadget..."
        cp "$GADGET_YAML" "$GADGET_YAML.orig"
        yq eval ".defaults.system.system.network.netplan = load(\"$NETWORK_FILE\")" -i "$GADGET_YAML"
        [ "$(yq eval '.defaults.system.system.network.netplan | type' "$GADGET_YAML")" = "!!map" ] \
            || die "A injeção do netplan produziu um valor inválido — verifica o network.yaml."
    fi

    info "snapcraft pack (pode demorar alguns minutos)..."
    ( cd "$GADGET_DIR" && snapcraft pack )

    # Repõe o gadget.yaml original imediatamente
    [ -f "$GADGET_YAML.orig" ] && mv -f "$GADGET_YAML.orig" "$GADGET_YAML"

    # Sem nomes hardcoded: apanha o .snap mais recente produzido
    local produced
    produced=$(ls -t "$GADGET_DIR"/*.snap 2>/dev/null | head -1)
    [ -n "$produced" ] || die "snapcraft pack terminou mas não encontrei nenhum .snap em $GADGET_DIR"

    mv "$produced" "$gadget_out"
    ok "Gadget construído: $(basename "$produced") → $gadget_out"
}

# ══════════════════════════════════════════════════════════════════
#  Imagem final
# ══════════════════════════════════════════════════════════════════
build_image() {
    stage "4/4 · Imagem Ubuntu Core (ubuntu-image)"

    local run_id out_dir
    run_id="$(date -u '+%Y%m%d-%H%M%S')_${MODEL_NAME}"
    out_dir="$OUTPUT_DIR/$run_id"
    mkdir -p "$out_dir"

    ubuntu-image snap "$BUILD_DIR/model.model" \
        --snap "$BUILD_DIR/gadget.snap" \
        --assertion "$BUILD_DIR/system-user.assert" \
        -O "$out_dir"

    # Metadados de proveniência (rastreabilidade para a dissertação)
    {
        echo "run-id:            $run_id"
        echo "date-utc:          $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "model:             $MODEL_NAME ($ARCHITECTURE, $BASE, grade=$GRADE)"
        echo "developer-id:      $DEVELOPER_ID"
        echo "signing-key:       $KEY_NAME"
        echo "gadget-git-rev:    $(git -c safe.directory='*' -C "$GADGET_DIR" rev-parse --short HEAD 2>/dev/null || echo 'n/a')"
        echo "snapcraft:         $(snapcraft --version 2>/dev/null || echo 'n/a')"
        echo "ubuntu-image:      $(ubuntu-image --version 2>/dev/null | head -1 || echo 'n/a')"
    } > "$out_dir/build-info.txt"

    if [ "$COMPRESS_IMAGE" = "true" ]; then
        info "A comprimir imagem com xz (multi-thread)..."
        xz -T0 -6 "$out_dir"/*.img
    fi

    ( cd "$out_dir" && sha256sum ./*.img* > SHA256SUMS 2>/dev/null || true )

    ln -sfn "$run_id" "$OUTPUT_DIR/latest"

    echo ""
    ok "${C_BOLD}Imagem gerada com sucesso!${C_RESET}"
    info "Diretório:  $out_dir  (atalho: $OUTPUT_DIR/latest)"
    ls -lh "$out_dir"
}

# ══════════════════════════════════════════════════════════════════
#  Doctor — diagnóstico do ambiente
# ══════════════════════════════════════════════════════════════════
cmd_doctor() {
    stage "Diagnóstico do ambiente"
    local fail=0

    check() {  # check <descrição> <comando...>
        local desc=$1; shift
        if "$@" &>/dev/null; then
            echo "  ${C_GREEN}✔${C_RESET} $desc"
        else
            echo "  ${C_RED}✖${C_RESET} $desc"
            fail=1
        fi
    }

    check "Ficheiro .env presente"                 test -f "$ENV_FILE"
    check "jq instalado"                           command -v jq
    check "yq instalado"                           command -v yq
    check "gpg instalado"                          command -v gpg
    check "snapcraft instalado"                    command -v snapcraft
    check "ubuntu-image instalado"                 command -v ubuntu-image
    check "Template model presente"                test -f "$MODEL_TEMPLATE"
    check "Template system-user presente"          test -f "$SYSTEM_USER_TEMPLATE"
    check "Chaves SSH configuradas"                test -s "$SSH_KEYS_FILE"
    check "Diretório do gadget presente"           test -d "$GADGET_DIR"

    if [ -f "$ENV_FILE" ]; then
        load_env
        setup_gpg
        check "Chave '$KEY_NAME' no keyring local"  key_exists
        check "Credenciais Snap Store válidas"      load_store_credentials
    fi

    echo ""
    if [ "$fail" -eq 0 ]; then
        ok "Ambiente pronto. Corre: pipeline.sh build"
    else
        warn "Há problemas por resolver. Para auth/chave corre: pipeline.sh setup"
        return 1
    fi
}

# ══════════════════════════════════════════════════════════════════
#  Subcomandos principais
# ══════════════════════════════════════════════════════════════════
cmd_setup() {
    stage "Setup inicial (interativo, executa uma vez)"
    load_env
    ensure_deps
    ensure_store_auth
    ensure_signing_key
    echo ""
    ok "Setup completo. A partir de agora 'pipeline.sh build' corre sem interação."
}

cmd_build() {
    load_env
    ensure_deps
    setup_gpg
    load_store_credentials || die "Sem credenciais válidas. Corre primeiro: pipeline.sh setup"
    key_exists             || die "Chave '$KEY_NAME' não existe. Corre primeiro: pipeline.sh setup"

    render_assertions
    sign_assertions
    build_gadget
    build_image
}

cmd_clean() {
    info "A remover artefactos de build (credenciais e chaves são preservadas)..."
    rm -rf "$BUILD_DIR"
    info "Para apagar também as imagens geradas: rm -rf $OUTPUT_DIR"
    ok "Limpo."
}

cmd_all() {
    load_env
    ensure_deps
    setup_gpg
    if ! load_store_credentials || ! key_exists; then
        cmd_setup
    fi
    cmd_build
}

usage() {
    # Imprime o cabeçalho deste ficheiro (entre as duas linhas ═══)
    awk '/^# ═/ {n++; next} n==1 {sub(/^# ? ?/, ""); print} n>=2 {exit}' "${BASH_SOURCE[0]}"
    exit 1
}

# ══════════════════════════════════════════════════════════════════
#  Main
# ══════════════════════════════════════════════════════════════════
CMD="${1:-}"
shift || true
for arg in "$@"; do
    case "$arg" in
        --rebuild-gadget) REBUILD_GADGET=1 ;;
        *) err "Opção desconhecida: $arg"; usage ;;
    esac
done

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/pipeline-$(date -u '+%Y%m%d-%H%M%S')-${CMD:-help}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

case "$CMD" in
    setup)  cmd_setup ;;
    build)  cmd_build ;;
    doctor) cmd_doctor || exit 1 ;;
    clean)  cmd_clean ;;
    all)    cmd_all ;;
    *)      usage ;;
esac
