#!/bin/bash
set -e

echo "╔════════════════════════════════════════════╗"
echo "║     Check Dependency Script                ║"
echo "╚════════════════════════════════════════════╝"
echo ""

# ── Instala dependências ──────────────────────────
install_deps() {
    echo "🔍 Verificando dependências..."
    local snap_tools=()
    local apt_tools=()

    command -v snapcraft    &>/dev/null || snap_tools+=("snapcraft")
    command -v ubuntu-image &>/dev/null || snap_tools+=("ubuntu-image")
    command -v gpg          &>/dev/null || apt_tools+=("gpg")
    command -v expect       &>/dev/null || apt_tools+=("expect")
    
    if [ ${#snap_tools[@]} -gt 0 ]; then
        echo "📦 Instalando via snap: ${snap_tools[*]}"
        for tool in "${snap_tools[@]}"; do
            case "$tool" in
                snapcraft) sudo snap install snapcraft --classic ;;
                ubuntu-image) sudo snap install ubuntu-image --classic ;;
            esac
        done
    fi

    if [ ${#apt_tools[@]} -gt 0 ]; then
        if command -v apt-get &>/dev/null; then
            echo "📦 Instalando via apt: ${apt_tools[*]}"
            sudo apt-get update -qq
            sudo apt-get install -y "${apt_tools[@]}"
        else
            echo "❌ Gestor de pacotes não suportado."
            exit 1
        fi
    fi
    echo "✅ Todas as dependências verificadas."
}


install_deps