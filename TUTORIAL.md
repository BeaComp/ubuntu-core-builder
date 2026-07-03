# Tutorial — do clone à imagem publicada 🚀

Guia completo para usar este pipeline num computador novo: clonar o
repositório, configurar o ambiente, gerar imagens Ubuntu Core localmente
e publicar versões via CI/CD. No fim, a lista de **pontos críticos de
segurança** que tens de conhecer.

---

## Parte 1 — Preparar a máquina nova

### 1.1 Pré-requisitos

| Ferramenta | Para quê | Instalação (Ubuntu) |
|---|---|---|
| git | clonar o repositório | `sudo apt install git` |
| Docker + Compose | ambiente de build isolado | [docs.docker.com/engine/install](https://docs.docker.com/engine/install/ubuntu/) |
| make | comandos de conveniência | `sudo apt install make` |
| GitHub CLI (`gh`) | secrets do CI e releases | [cli.github.com](https://cli.github.com) |

Depois de instalar o Docker, adiciona o teu utilizador ao grupo
(`sudo usermod -aG docker $USER` + logout/login) e autentica o `gh`:

```bash
gh auth login
```

Também vais precisar da tua conta **Ubuntu One** (a mesma de sempre) e,
se fores restaurar a chave de assinatura existente, do ficheiro de
backup `mestrado-iot-signing-key.asc` (ver secção 1.4).

### 1.2 Clonar (com o submodule!)

O `pi-gadget` é um submodule — um clone simples vem com a pasta vazia:

```bash
git clone --recurse-submodules https://github.com/BeaComp/ubuntu-core-builder.git
cd ubuntu-core-builder
```

Se já clonaste sem `--recurse-submodules`:

```bash
git submodule update --init
```

### 1.3 Obter o binário do meshagent

O binário do agente MeshCentral **não está no git** (decisão deliberada).
Vive como asset do release `meshagent-bin` no repositório `pi-gadget`:

```bash
gh release download meshagent-bin \
  --repo BeaComp/pi-gadget \
  --pattern meshagent \
  --output workspace/pi-gadget/gadget-source/meshagent-bin/meshagent
chmod +x workspace/pi-gadget/gadget-source/meshagent-bin/meshagent
```

Sem este passo, o build do gadget falha com
`meshagent-bin: No such file or directory`.

### 1.4 Configurar

```bash
cp workspace/config/.env.example workspace/.env
nano workspace/.env        # confirma KEY_NAME, dados do system-user
```

Confirma também que a tua chave SSH pública está em
`workspace/config/ssh-authorized-keys` — sem uma chave válida aí,
**não há forma de entrar no dispositivo** (o Ubuntu Core não tem login
por password). Se a máquina nova tiver outra chave SSH, acrescenta-a
(uma por linha).

(Opcional) Wi-Fi pré-configurado na imagem: preenche
`workspace/network.yaml` com netplan (`network:` no topo). **Nunca**
faças commit deste ficheiro com senhas — só builds locais devem ter Wi-Fi.

### 1.5 Arrancar o ambiente e autenticar

```bash
make up        # constrói e arranca o container (1ª vez demora)
```

**Se tens o backup da chave de assinatura** (o caso normal — a chave
`mestrado-iot` já está registada na Canonical), restaura-a ANTES do setup:

```bash
docker exec -i ubuntu-core-builder sh -c \
  'mkdir -p /root/.snap/gnupg && chmod 700 /root/.snap/gnupg && \
   gpg --homedir /root/.snap/gnupg --import' < mestrado-iot-signing-key.asc
```

Depois, o setup (interativo, uma vez por máquina — pede email, password
e 2FA do Ubuntu One; a password nunca fica guardada):

```bash
make setup
```

O setup deteta a chave restaurada e o registo na Canonical, e só faz o
login na Store (o token é por máquina).

**Se NÃO tens o backup da chave**: não podes registar outra chave com o
mesmo nome. Escolhe um `KEY_NAME` novo no `.env` antes do `make setup`
(que cria e regista a chave nova) e depois atualiza o CI com
`make ci-secrets`. As imagens antigas continuam válidas.

### 1.6 Verificar e construir

```bash
make doctor    # diagnóstico: tudo ✔?
make image     # build completo, não-interativo
```

A imagem fica em `workspace/output/latest/` com `SHA256SUMS` e
`build-info.txt`. Gravar no cartão SD:

```bash
sudo dd if=workspace/output/latest/pi.img of=/dev/sdX bs=32M status=progress
# (confirma o /dev/sdX com "lsblk" antes — o dd não perdoa!)
```

---

## Parte 2 — CI/CD e releases

O CI **não precisa de configuração na máquina nova** — os secrets vivem
no GitHub, independentes do computador. Só voltas a correr
`make ci-secrets` se rodares o token ou a chave.

### Publicar uma versão

```bash
git tag v0.2.0
git push origin v0.2.0
```

≈5 minutos depois:
`https://github.com/BeaComp/ubuntu-core-builder/releases/tag/v0.2.0`
com `pi.img.xz`, `SHA256SUMS`, `build-info.txt` e `seed.manifest`.

Num computador novo, verifica a integridade do que descarregares:

```bash
sha256sum -c SHA256SUMS
xz -dc pi.img.xz | sudo dd of=/dev/sdX bs=32M status=progress
```

### Build de teste sem release

GitHub → Actions → *build-image* → **Run workflow**. O resultado fica
como artefacto de workflow (7 dias), sem criar release.

### Alterar o gadget (pi-gadget é submodule!)

```bash
cd workspace/pi-gadget
# ... editas, commit ...
git push origin 24
cd ../..
git add workspace/pi-gadget    # atualiza o commit apontado
git commit -m "bump pi-gadget" && git push
```

O CI usa **o commit apontado pelo repositório principal**, não o teu
working tree — se te esqueceres do `git add workspace/pi-gadget`, o CI
constrói a versão antiga.

### Atualizar o binário do meshagent

```bash
gh release upload meshagent-bin novo-meshagent --clobber --repo BeaComp/pi-gadget
```

---

## Parte 3 — Pontos críticos de segurança ⚠️

### P1. A chave de assinatura só existe em dois sítios — e um deles é write-only

A chave GPG privada (que assina `model` e `system-user`) vive em
`/root/.snap/gnupg` **dentro do container** e no secret `SNAP_SIGNING_KEY`
do GitHub. O secret **não pode ser lido de volta**, e o container é
efémero: `docker compose down` ou `make rebuild` **destroem a única
cópia legível**. Mantém sempre um backup fora de qualquer repositório git:

```bash
docker exec ubuntu-core-builder gpg --homedir /root/.snap/gnupg \
  --export-secret-keys --armor mestrado-iot > mestrado-iot-signing-key.asc
chmod 600 mestrado-iot-signing-key.asc
```

Quem tiver esta chave consegue assinar imagens e system-users **válidos
em teu nome** — dispositivos com o teu model aceitá-los-iam. Se for
comprometida: remove-a em [dashboard.snapcraft.io](https://dashboard.snapcraft.io)
e roda para uma chave nova (`KEY_NAME` novo + `make setup` + `make ci-secrets`).

### P2. O token da Snap Store é uma credencial da tua conta de developer

Vive em `workspace/.credentials/snapcraft-store.txt` (chmod 600, no
`.gitignore`) e no secret `SNAPCRAFT_STORE_CREDENTIALS`. Dá acesso à tua
conta de publisher (registar chaves, publicar snaps). Expira ≈1 ano —
quando o CI falhar com "credenciais inválidas": `make setup` +
`make ci-secrets`. Se suspeitares de fuga, revoga as sessões em
[login.ubuntu.com](https://login.ubuntu.com).

A **password do Ubuntu One nunca é armazenada** em lado nenhum — o login
é interativo (com 2FA) e só o token derivado é guardado.

### P3. Os repositórios são PÚBLICOS — sabe o que se vê

Visível para qualquer pessoa: todo o código, o teu email/username do
Ubuntu One, a tua chave SSH **pública** (inofensiva sem a privada), o
developer-id, o binário do meshagent, e as **imagens completas** nos
releases. Invisível: os secrets (cifrados e mascarados nos logs; não são
entregues a workflows de forks) e a senha do Wi-Fi (o `network.yaml`
versionado está vazio de propósito).

### P4. O `meshagent.msh` público é uma credencial de enrollment

O ficheiro versionado no `pi-gadget` contém `MeshID`, `ServerID` e o URL
do teu servidor MeshCentral. Quem o conhecer pode **juntar um dispositivo
falso ao teu mesh** e sabe onde está o teu servidor. Mitigações: usar um
device group descartável para testes (o nome `QUARANTINE` é boa prática),
ativar aprovação manual/invite codes no MeshCentral, e vigiar dispositivos
desconhecidos no grupo. Alternativa mais forte: tirar o `.msh` do git e
distribuí-lo como asset de release, como o binário.

### P5. `grade: dangerous` é para desenvolvimento

O model atual usa `grade: dangerous`, que aceita snaps não-asserted e é
adequado à fase de desenvolvimento. Para dispositivos "de produção" da
dissertação, muda para `grade: signed` no `.env` (`GRADE=signed`) — a
imagem passa a exigir que tudo esteja assinado.

### P6. Acesso ao dispositivo = chave SSH privada

O Ubuntu Core não tem login por password. O acesso é exclusivamente por
SSH com as chaves públicas embebidas no system-user (mais as da conta
Ubuntu One, via console-conf). Protege as chaves privadas correspondentes
(`~/.ssh/id_*`) — quem as tiver entra nos dispositivos. Em máquina nova,
gera um par novo (`ssh-keygen -t ed25519`) e acrescenta a pública ao
`ssh-authorized-keys` em vez de copiares a privada entre máquinas.

### P7. Senhas de Wi-Fi nunca entram no git nem no CI

O pipeline injeta o `network.yaml` no gadget apenas em builds locais e
reverte o `gadget.yaml` no fim (mesmo com erro). O CI constrói sempre sem
Wi-Fi (Ethernet/console-conf no primeiro arranque). Se um dia precisares
de Wi-Fi em imagens do CI, o caminho certo é um secret — nunca um commit.

### Resumo — onde vive cada segredo

| Segredo | Local | GitHub | Risco se vazar |
|---|---|---|---|
| Chave GPG privada | container `/root/.snap/gnupg` + backup teu | secret (write-only) | assinar imagens em teu nome |
| Token Snap Store | `.credentials/` (600, gitignored) | secret (write-only) | controlo da conta de publisher |
| Password Ubuntu One | **nunca armazenada** | — | (protegida por 2FA) |
| Senha Wi-Fi | só `network.yaml` local (não commitado) | — | acesso à tua rede |
| Chave SSH privada | `~/.ssh/` da tua máquina | — | acesso aos dispositivos |
