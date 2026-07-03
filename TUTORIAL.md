# Tutorial — do clone à imagem publicada 🚀

Guia completo: clonar, configurar, gerar imagens Ubuntu Core localmente
e (opcional) montar CI/CD com GitHub Actions para publicar cada versão
como GitHub Release. No fim, os **pontos críticos de segurança**.

> ⚠️ Trabalha sempre numa **cópia privada** deste repositório — a tua
> versão vai conter dados pessoais e secrets (ver aviso no README).

---

## Parte 1 — Build local

### 1.1 Pré-requisitos

| Ferramenta | Para quê | Instalação (Ubuntu) |
|---|---|---|
| git | clonar o repositório | `sudo apt install git` |
| Docker + Compose | ambiente de build isolado | [docs.docker.com](https://docs.docker.com/engine/install/ubuntu/) |
| make | comandos de conveniência | `sudo apt install make` |
| GitHub CLI (`gh`) | secrets do CI e releases | [cli.github.com](https://cli.github.com) |

E uma conta **Ubuntu One** com os termos de developer aceites em
[dashboard.snapcraft.io](https://dashboard.snapcraft.io).

### 1.2 Clonar (com o submodule!)

O gadget é um submodule — um clone simples vem com a pasta vazia:

```bash
git clone --recurse-submodules <URL-DA-TUA-CÓPIA-PRIVADA>
cd <o-teu-builder>
# já clonaste sem --recurse-submodules? → git submodule update --init
```

Se o teu gadget precisar de binários externos não versionados (ex.: um
agente de gestão remota), coloca-os agora no sítio esperado pelo
`snapcraft.yaml` do gadget — vê a secção 2.4 para uma forma limpa de os
distribuir.

### 1.3 Configurar

```bash
cp workspace/config/.env.example workspace/.env
nano workspace/.env    # KEY_NAME, dados do system-user, etc.

cp workspace/config/ssh-authorized-keys.example workspace/config/ssh-authorized-keys
nano workspace/config/ssh-authorized-keys   # cola a tua chave PÚBLICA
```

⚠️ O Ubuntu Core **não tem login por password** — sem uma chave SSH
válida em `ssh-authorized-keys`, não há forma de aceder ao dispositivo.

(Opcional) Wi-Fi pré-configurado: preenche `workspace/network.yaml`
com netplan (`network:` no topo). Este ficheiro está no `.gitignore` —
**nunca** o removas de lá: contém a senha da tua rede.

### 1.4 Arrancar e autenticar

```bash
make up      # constrói e arranca o container (1ª vez demora)
make setup   # interativo, 1 vez: login Ubuntu One (2FA ok) +
             # criação e registo da chave de assinatura
```

A password nunca fica guardada — só um token revogável
(`workspace/.credentials/`, chmod 600, gitignored).

**Máquina nova com chave já existente?** Não podes registar outra chave
com o mesmo nome. Restaura o backup ANTES do `make setup`:

```bash
docker exec -i ubuntu-core-builder sh -c \
  'mkdir -p /root/.snap/gnupg && chmod 700 /root/.snap/gnupg && \
   gpg --homedir /root/.snap/gnupg --import' < a-tua-chave-backup.asc
```

### 1.5 Construir

```bash
make doctor    # diagnóstico: tudo ✔?
make image     # build completo, não-interativo
```

Resultado em `workspace/output/latest/`:

```bash
sudo dd if=workspace/output/latest/pi.img of=/dev/sdX bs=32M status=progress
# confirma o /dev/sdX com "lsblk" — o dd não perdoa!
```

---

## Parte 2 — Montar o CI/CD (GitHub Actions)

O objetivo: `git tag v1.0.0 && git push origin v1.0.0` → o GitHub
constrói a imagem e publica-a como **Release** com checksums e
proveniência. Só faz sentido num repositório **privado** (os secrets
dão acesso à tua conta de developer, e as imagens ficam acessíveis a
quem vê o repositório).

### 2.1 Criar os secrets

| Secret | Conteúdo | Como obter |
|---|---|---|
| `SNAPCRAFT_STORE_CREDENTIALS` | token da Snap Store | `docker exec ubuntu-core-builder cat /workspace/.credentials/snapcraft-store.txt` |
| `SNAP_SIGNING_KEY` | chave GPG privada (armored) | `docker exec ubuntu-core-builder gpg --homedir /root/.snap/gnupg --export-secret-keys --armor <KEY_NAME>` |
| `KEY_NAME` | nome da chave | o teu `.env` |
| `SYSTEM_USER_EMAIL` | email Ubuntu One | o teu `.env` |
| `SYSTEM_USER_USERNAME` | username do system-user | o teu `.env` |
| `SYSTEM_USER_FULLNAME` | nome completo | o teu `.env` |
| `SSH_AUTHORIZED_KEYS` | chaves SSH públicas (uma por linha) | `config/ssh-authorized-keys` |
| `KEY_PASSPHRASE` | (opcional) passphrase da chave | o teu `.env` |

Com o `gh` autenticado, dentro do teu repositório:

```bash
gh secret set NOME_DO_SECRET   # cola o valor, ou usa --body / stdin
```

Assim **nenhum dado pessoal fica no git** — nem sequer no privado: o
workflow constrói o `.env` a partir dos secrets em tempo de execução.

### 2.2 O workflow

Cria `.github/workflows/build-image.yml` com o conteúdo abaixo
(substitui `<TEU-USER>/<TEU-GADGET>` se usares o passo do binário
externo; caso contrário remove esse passo):

```yaml
name: build-image

on:
  push:
    tags: ["v*"]
  workflow_dispatch:

permissions:
  contents: write

jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - name: Checkout (inclui o gadget)
        uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: Instalar ferramentas
        run: |
          sudo snap install snapcraft --classic
          sudo snap install ubuntu-image --classic
          sudo snap install lxd
          sudo lxd init --auto
          # O Docker pré-instalado no runner põe FORWARD em DROP,
          # o que corta a rede aos containers LXD do snapcraft
          sudo iptables -I DOCKER-USER -i lxdbr0 -j ACCEPT || true
          sudo iptables -I DOCKER-USER -o lxdbr0 -j ACCEPT || true
          sudo curl -fsSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
            -o /usr/local/bin/yq
          sudo chmod +x /usr/local/bin/yq

      - name: Configurar autenticação (Store + chave de assinatura)
        env:
          STORE_CREDENTIALS: ${{ secrets.SNAPCRAFT_STORE_CREDENTIALS }}
          SIGNING_KEY: ${{ secrets.SNAP_SIGNING_KEY }}
        run: |
          test -n "$STORE_CREDENTIALS" || { echo "::error::Secret SNAPCRAFT_STORE_CREDENTIALS em falta"; exit 1; }
          test -n "$SIGNING_KEY"       || { echo "::error::Secret SNAP_SIGNING_KEY em falta"; exit 1; }
          install -d -m 700 workspace/.credentials
          printf '%s' "$STORE_CREDENTIALS" > workspace/.credentials/snapcraft-store.txt
          chmod 600 workspace/.credentials/snapcraft-store.txt
          # O pipeline corre como root → keyring do snap em /root/.snap/gnupg
          sudo install -d -m 700 /root/.snap/gnupg
          printf '%s' "$SIGNING_KEY" | sudo env GNUPGHOME=/root/.snap/gnupg gpg --batch --import

      - name: (Opcional) Obter binários externos do gadget
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          # Exemplo: binário distribuído como asset de um release dedicado
          gh release download <TAG-DO-RELEASE> \
            --repo <TEU-USER>/<TEU-GADGET> \
            --pattern <binario> \
            --output workspace/pi-gadget/<caminho-esperado>/<binario>
          chmod +x workspace/pi-gadget/<caminho-esperado>/<binario>

      - name: Preparar .env e chaves SSH (a partir de secrets)
        env:
          KEY_NAME: ${{ secrets.KEY_NAME }}
          KEY_PASSPHRASE: ${{ secrets.KEY_PASSPHRASE }}
          SYSTEM_USER_EMAIL: ${{ secrets.SYSTEM_USER_EMAIL }}
          SYSTEM_USER_USERNAME: ${{ secrets.SYSTEM_USER_USERNAME }}
          SYSTEM_USER_FULLNAME: ${{ secrets.SYSTEM_USER_FULLNAME }}
          SSH_AUTHORIZED_KEYS: ${{ secrets.SSH_AUTHORIZED_KEYS }}
        run: |
          for v in KEY_NAME SYSTEM_USER_EMAIL SYSTEM_USER_USERNAME SSH_AUTHORIZED_KEYS; do
            test -n "${!v}" || { echo "::error::Secret $v em falta"; exit 1; }
          done
          {
            echo "KEY_NAME=$KEY_NAME"
            echo "KEY_PASSPHRASE=$KEY_PASSPHRASE"
            echo "MODEL_NAME=rpi5-gateway"
            echo "ARCHITECTURE=arm64"
            echo "BASE=core24"
            echo "GRADE=dangerous"
            echo "SYSTEM_USER_EMAIL=$SYSTEM_USER_EMAIL"
            echo "SYSTEM_USER_USERNAME=$SYSTEM_USER_USERNAME"
            echo "SYSTEM_USER_FULLNAME=\"${SYSTEM_USER_FULLNAME:-$SYSTEM_USER_USERNAME}\""
            echo "SYSTEM_USER_VALID_YEARS=10"
            # Assets de um Release têm limite de 2 GB → compressão obrigatória
            echo "COMPRESS_IMAGE=true"
          } > workspace/.env
          printf '%s\n' "$SSH_AUTHORIZED_KEYS" > workspace/config/ssh-authorized-keys

      - name: Build da imagem
        run: |
          # HOME=/root: sob sudo, o snapd resolveria o keyring pelo
          # utilizador real (runner); forçamos o mesmo dir do import
          sudo -E env "PATH=$PATH" HOME=/root \
            WORKSPACE="$GITHUB_WORKSPACE/workspace" \
            ./workspace/pipeline.sh build
          OUT=$(readlink -f workspace/output/latest)
          sudo chmod -R a+r "$OUT"
          echo "OUT=$OUT" >> "$GITHUB_ENV"

      - name: Publicar GitHub Release
        if: startsWith(github.ref, 'refs/tags/')
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          {
            echo '```'
            cat "$OUT/build-info.txt"
            echo '```'
          } > /tmp/release-notes.md
          gh release create "$GITHUB_REF_NAME" \
            --title "Ubuntu Core $GITHUB_REF_NAME" \
            --notes-file /tmp/release-notes.md \
            "$OUT"/pi.img.xz "$OUT"/SHA256SUMS "$OUT"/build-info.txt "$OUT"/seed.manifest

      - name: Guardar artefacto (execução manual)
        if: "!startsWith(github.ref, 'refs/tags/')"
        uses: actions/upload-artifact@v4
        with:
          name: ubuntu-core-image
          path: ${{ env.OUT }}
          retention-days: 7
```

### 2.3 Publicar uma versão

```bash
git tag v1.0.0
git push origin v1.0.0
# ≈5 min depois: .../releases/tag/v1.0.0 com pi.img.xz + SHA256SUMS
```

Para um build de teste sem release: Actions → build-image →
**Run workflow** (o resultado fica como artefacto, 7 dias).

Verificar integridade do que descarregares:

```bash
sha256sum -c SHA256SUMS
xz -dc pi.img.xz | sudo dd of=/dev/sdX bs=32M status=progress
```

### 2.4 Binários externos do gadget

Se o teu gadget precisa de binários que não devem ir para o git
(agentes, firmware, blobs), o padrão limpo é publicá-los **uma vez**
como asset de um release dedicado do repositório do gadget:

```bash
gh release create meu-binario --latest=false --title "..." caminho/binario
```

…e descarregá-los no CI com `gh release download` (passo opcional do
workflow acima). Atenção: num repositório público, os assets são
públicos — binários que contenham identificadores/credenciais do teu
ambiente devem viver em repositório privado.

### 2.5 O gadget é um submodule

O CI usa **o commit do gadget apontado pelo repositório principal**,
não o teu working tree:

```bash
cd workspace/pi-gadget
# ... commit + push no repo do gadget ...
cd ../..
git add workspace/pi-gadget && git commit -m "bump gadget" && git push
```

---

## Parte 3 — Pontos críticos de segurança ⚠️

### P1. A chave de assinatura: backup obrigatório

A chave GPG privada (assina `model` e `system-user`) vive em
`/root/.snap/gnupg` **dentro do container** — que é efémero:
`docker compose down` ou `make rebuild` **destroem-na**. O secret no
GitHub não pode ser lido de volta (write-only). Faz backup já:

```bash
docker exec ubuntu-core-builder gpg --homedir /root/.snap/gnupg \
  --export-secret-keys --armor <KEY_NAME> > chave-backup.asc
chmod 600 chave-backup.asc    # guarda FORA de qualquer repositório git
```

Quem tiver esta chave assina imagens e system-users **válidos em teu
nome**. Comprometida? Remove-a em dashboard.snapcraft.io e roda
(`KEY_NAME` novo + `make setup` + refazer secrets).

### P2. O token da Store é a tua conta de developer

Dá acesso à conta de publisher (registar chaves, publicar snaps).
Expira ≈1 ano → `make setup` + refazer o secret. Fuga suspeita →
revogar sessões em login.ubuntu.com. A **password do Ubuntu One nunca
é armazenada** — o login é interativo, com 2FA.

### P3. Repositório privado, sempre

Com o repositório privado: secrets, imagens (releases/artefactos) e
histórico só são visíveis para quem tu autorizares. Os GitHub Secrets
são cifrados, mascarados nos logs e não são entregues a workflows de
forks — mas os **assets e o código de um repo público são de todos**.
Lembra-te: o que entrou no git uma vez fica no **histórico** mesmo
depois de apagado — segredo commitado é segredo comprometido (roda-o).

### P4. Dados pessoais só em secrets e ficheiros gitignored

Neste pipeline, `.env`, `ssh-authorized-keys` e `network.yaml` são
gitignored, e o CI recebe tudo via secrets. Antes de cada commit:
`git status` — se aparecer um destes ficheiros, algo está errado.

### P5. `grade: dangerous` é para desenvolvimento

Aceita snaps não-asserted. Para dispositivos de produção usa
`GRADE=signed` — a imagem passa a exigir tudo assinado.

### P6. Acesso ao dispositivo = chave SSH privada

O Ubuntu Core só aceita SSH por chave (as públicas do system-user +
as da conta Ubuntu One). Protege as privadas (`~/.ssh/id_*`); em
máquina nova, gera um par novo e acrescenta a pública — não copies a
privada entre máquinas.

### P7. Identificadores de agentes/gestão remota são credenciais

Ficheiros de configuração de agentes (ex.: MeshCentral `.msh` com
`MeshID`/`ServerID`/URL do servidor) funcionam como **credenciais de
enrollment**: quem os tiver pode registar dispositivos falsos no teu
servidor. Nunca os publiques; distribui-os por secret ou repositório
privado, e monitoriza dispositivos desconhecidos.

### Resumo — onde vive cada segredo

| Segredo | Local | GitHub | Risco se vazar |
|---|---|---|---|
| Chave GPG privada | container + backup teu | secret (write-only) | assinar imagens em teu nome |
| Token Snap Store | `.credentials/` (600, gitignored) | secret | controlo da conta de publisher |
| Password Ubuntu One | **nunca armazenada** | — | (protegida por 2FA) |
| Dados pessoais (email, SSH pub, …) | `.env` local (gitignored) | secrets | doxxing / spam |
| Senha Wi-Fi | `network.yaml` local (gitignored) | — | acesso à tua rede |
| Chave SSH privada | `~/.ssh/` da tua máquina | — | acesso aos dispositivos |
