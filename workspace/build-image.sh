#!/bin/bash
set -e

# Exportações Globais Mágicas (Resolve o erro de chave não encontrada)
export PATH=$PATH:/snap/bin
export GNUPGHOME=/root/.snap/gnupg
export ENV_FILE="/workspace/.env"
export CRED_FILE="/workspace/credentials.txt"

echo "╔════════════════════════════════════════════╗"
echo "║     Ubuntu Core Image Builder              ║"
echo "╚════════════════════════════════════════════╝"
echo ""

# ── Carrega .env ──────────────────────────────────
load_env() {
    if [ ! -f "$ENV_FILE" ]; then
        echo "❌ Ficheiro .env não encontrado em /workspace/.env"
        exit 1
    fi

    set -a
    source "$ENV_FILE"
    set +a

    local missing=()
    [ -z "$KEY_NAME" ]           && missing+=("KEY_NAME")
    [ -z "$KEY_PASSPHRASE" ]     && missing+=("KEY_PASSPHRASE")
    [ -z "$SNAPCRAFT_EMAIL" ]    && missing+=("SNAPCRAFT_EMAIL")
    [ -z "$SNAPCRAFT_PASSWORD" ] && missing+=("SNAPCRAFT_PASSWORD")

    if [ ${#missing[@]} -gt 0 ]; then
        echo "❌ Campos obrigatórios em falta no .env: ${missing[*]}"
        exit 1
    fi

    echo "✅ Configuração carregada."
}

# ── Configurações de Segurança do GPG ─────────────
setup_gpg_config() {
    # Garante que o robô consiga inserir a passphrase sem travar em janelas visuais
    mkdir -p "$GNUPGHOME"
    chmod 700 "$GNUPGHOME"
    echo "pinentry-mode loopback" > "$GNUPGHOME/gpg.conf"
    echo "allow-loopback-pinentry" > "$GNUPGHOME/gpg-agent.conf"
    gpgconf --kill gpg-agent 2>/dev/null || true
}

# ── Setup das Credenciais ─────────────────────────
setup_credentials() {
    if [ -f "$CRED_FILE" ]; then
        echo "🔐 Credenciais já existem em credentials.txt."
    else
        echo "🔐 Fazendo login no Snapcraft e gerando token..."
        expect <<'EOF'
        log_user 0
        set timeout 60
        spawn /snap/bin/snapcraft export-login $env(CRED_FILE)
        expect {
            "Email:" { send "$env(SNAPCRAFT_EMAIL)\r"; exp_continue }
            "Password:" { send "$env(SNAPCRAFT_PASSWORD)\r"; exp_continue }
            "Second-factor*" { puts "\n❌ ERRO: Conta com 2FA ativada."; exit 1 }
            eof
        }
EOF
        chmod 600 "$CRED_FILE"
        echo "   ✅ Token guardado com segurança."
    fi

    export SNAPCRAFT_STORE_CREDENTIALS=$(cat "$CRED_FILE")
    echo "   ✅ Autenticação ativada para a sessão."
}


# ── Build do gadget ───────────────────────────────
build_gadget() {
    echo "⚙️  Construindo o pi-gadget customizado..."
    cd /workspace/pi-gadget

    local NETWORK_FILE="/workspace/network.yaml"
    local GADGET_YAML="gadget.yaml"

    if [ -f "$NETWORK_FILE" ]; then
        echo "   🌐 Injetando configurações de rede..."
        yq eval '.defaults.system.system.network.netplan = load("'$NETWORK_FILE'")' -i "$GADGET_YAML"
        echo "   ✅ Rede aplicada."
    fi

    snapcraft pack
    
    ARQUIVO_GADGET=$(ls pi_24-3_*.snap | tail -n 1)
    mv "$ARQUIVO_GADGET" /workspace/
    echo "   ✅ Gadget construído: $ARQUIVO_GADGET"
    cd /workspace
}

# ── Assina e gera imagem ──────────────────────────
build_image() {
    echo "✍️  Assinando model e system-user..."
    # Como GNUPGHOME está exportado lá no topo, não precisamos mais passar na frente do comando!
    snap sign -k "$KEY_NAME" system-user.json --chain > system-user.assert
    snap sign -k "$KEY_NAME" model.json > model.model

    echo "💿 Gerando imagem Ubuntu Core..."
    ubuntu-image snap model.model \
        --snap "/workspace/$ARQUIVO_GADGET" \
        --assertion=system-user.assert \
        -O /workspace/output-image

    echo ""
    echo "╔════════════════════════════════════════════╗"
    echo "║      Imagem gerada com sucesso! ✅         ║"
    echo "╚════════════════════════════════════════════╝"
    echo "📁 Localização: /workspace/output-image"
}

# ── Main ──────────────────────────────────────────
load_env
echo ""
setup_credentials
echo ""
build_gadget
echo ""
build_image