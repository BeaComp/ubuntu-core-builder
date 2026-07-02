# Ubuntu Core Image Pipeline 🏗️

Pipeline automatizado para criação de imagens **Ubuntu Core** personalizadas
(Raspberry Pi 5), no âmbito da dissertação *Autocomissionamento e gestão
remota segura para IoT*.

Todo o processo — autenticação, gestão de chaves, geração e assinatura das
assertions (`model` e `system-user`), build do gadget e geração da imagem —
é orquestrado por um único script com subcomandos, dentro de um container
Docker reprodutível.

## Arquitetura

```
ubuntu-core-builder/
├── Makefile                  # comandos de conveniência (host)
├── Dockerfile                # ambiente de build (systemd + snapd)
├── docker-compose.yaml
└── workspace/                # montado em /workspace no container
    ├── pipeline.sh           # orquestrador: setup | build | doctor | clean | all
    ├── lib/common.sh         # logging, .env, gpg, credenciais
    ├── config/
    │   ├── .env.example      # → copiar para workspace/.env
    │   ├── model.template.json
    │   ├── system-user.template.json
    │   └── ssh-authorized-keys
    ├── network.yaml          # (opcional) netplan injetado no gadget
    ├── pi-gadget/            # fonte do gadget snap
    ├── build/                # artefactos intermédios (gerado)
    ├── output/<run-id>/      # imagens finais + SHA256SUMS + build-info.txt
    ├── logs/                 # log de cada execução (gerado)
    └── .credentials/         # token da Snap Store (gerado, chmod 600)
```

## Fluxo do build

```
setup (1 vez, interativo)          build (repetível, não-interativo)
┌────────────────────────┐         ┌─────────────────────────────────┐
│ 1. login Ubuntu One    │         │ 1. render assertions            │
│    (suporta 2FA)       │         │    developer-id ← whoami        │
│ 2. criar chave GPG     │  ────▶  │ 2. snap sign (model +           │
│    (RSA 4096, batch)   │         │    system-user --chain)         │
│ 3. registar chave na   │         │ 3. snapcraft pack (gadget,      │
│    Canonical           │         │    com cache + netplan)         │
└────────────────────────┘         │ 4. ubuntu-image → output/       │
                                   └─────────────────────────────────┘
```

## Início rápido

```bash
# 0. Pré-requisitos: conta Ubuntu One + termos aceites em
#    https://dashboard.snapcraft.io

# 1. Configuração
cp workspace/config/.env.example workspace/.env
#    → edita workspace/.env (KEY_NAME, passphrase, dados do system-user)
#    → confirma a tua chave pública em workspace/config/ssh-authorized-keys
#    → (opcional) edita workspace/network.yaml com o teu Wi-Fi

# 2. Ambiente
make up          # arranca o container e espera pelo snapd

# 3. Setup inicial — UMA vez (pede email/password/2FA do Ubuntu One)
make setup

# 4. Build da imagem — sempre que precisares, sem interação
make image
```

A imagem fica em `workspace/output/<data>_<modelo>/` (atalho
`workspace/output/latest/`), acompanhada de `SHA256SUMS` e de um
`build-info.txt` com a proveniência completa do build (developer-id, chave,
revisão git do gadget, versões das ferramentas).

Gravar no cartão SD:

```bash
xz -dc workspace/output/latest/*.img.xz | sudo dd of=/dev/sdX bs=32M status=progress
# ou, sem compressão:
sudo dd if=workspace/output/latest/pi.img of=/dev/sdX bs=32M status=progress
```

## Comandos

| Comando | Descrição |
|---|---|
| `make up` / `make down` | Arranca / pára o container |
| `make setup` | Login na Store + criação e registo da chave (interativo, 1 vez) |
| `make image` | Build completo, não-interativo |
| `make gadget` | Build forçando a reconstrução do gadget |
| `make doctor` | Diagnóstico: dependências, credenciais, chave, templates |
| `make clean` | Remove artefactos intermédios (preserva credenciais/imagens) |
| `make shell` | Bash dentro do container |

Dentro do container os mesmos subcomandos existem em
`/workspace/pipeline.sh <setup|build|doctor|clean|all>`.

## Configuração (`workspace/.env`)

| Variável | Descrição | Omissão |
|---|---|---|
| `KEY_NAME` | Nome da chave de assinatura | *(obrigatório)* |
| `KEY_PASSPHRASE` | Passphrase da chave; vazio = sem passphrase (CI) | vazio |
| `MODEL_NAME` | Nome do modelo (assertion `model`) | `rpi5-gateway` |
| `ARCHITECTURE` / `BASE` / `GRADE` | Parâmetros do modelo | `arm64` / `core24` / `dangerous` |
| `SYSTEM_USER_EMAIL` / `USERNAME` / `FULLNAME` | Utilizador criado no 1º arranque | *(obrigatório)* |
| `SYSTEM_USER_VALID_YEARS` | Validade da asserção system-user | `10` |
| `COMPRESS_IMAGE` | `true` = comprime a imagem com xz | `false` |

Os snaps incluídos na imagem definem-se em
`workspace/config/model.template.json` (lista `snaps`). Os campos de
identidade (`authority-id`, `brand-id`, `timestamp`, …) são preenchidos
automaticamente pelo pipeline — **nunca é preciso editá-los à mão**.

## CI/CD (GitHub Actions)

O workflow [.github/workflows/build-image.yml](.github/workflows/build-image.yml)
constrói a imagem no GitHub e publica-a:

- **`git push` de uma tag `v*`** → build + **GitHub Release** com
  `pi.img.xz`, `SHA256SUMS`, `build-info.txt` e `seed.manifest`
- **Execução manual** (Actions → build-image → Run workflow) → build +
  artefacto de workflow (retenção de 7 dias), sem criar release

O CI corre o mesmo `pipeline.sh build` usado localmente, diretamente no
runner (sem Docker — o runner já tem snapd), com `COMPRESS_IMAGE=true`
forçado porque os assets de um Release têm limite de 2 GB por ficheiro.

### Configuração (uma vez)

O CI precisa de dois secrets — os mesmos materiais que o `make setup`
criou localmente. Com o [GitHub CLI](https://cli.github.com) autenticado:

```bash
make ci-secrets
```

Ou manualmente (Settings → Secrets and variables → Actions):

| Secret | Conteúdo |
|---|---|
| `SNAPCRAFT_STORE_CREDENTIALS` | `docker exec ubuntu-core-builder cat /workspace/.credentials/snapcraft-store.txt` |
| `SNAP_SIGNING_KEY` | `docker exec ubuntu-core-builder gpg --homedir /root/.snap/gnupg --export-secret-keys --armor <KEY_NAME>` |
| `KEY_PASSPHRASE` | (só se a chave tiver passphrase) |

### Publicar uma versão

```bash
git tag v0.1.0
git push origin v0.1.0
# → https://github.com/BeaComp/ubuntu-core-builder/releases/tag/v0.1.0
```

Notas:

- O `pi-gadget` entra no CI como **submodule**: o build usa o commit
  apontado pelo repositório principal. Depois de alterares o gadget,
  faz commit+push no `pi-gadget` e depois `git add workspace/pi-gadget`
  + commit no repositório principal.
- O Wi-Fi **não** é injetado no CI (o `network.yaml` versionado está
  vazio de propósito — nunca commits senhas de Wi-Fi). Imagens do CI
  arrancam com Ethernet/console-conf; para imagens com Wi-Fi usa o
  build local.
- O token da Store expira (≈1 ano por omissão). Quando o CI falhar com
  credenciais inválidas: `make setup` local e `make ci-secrets` de novo.

## Decisões de segurança

- **Sem passwords em ficheiros.** O login no Ubuntu One é interativo e feito
  uma única vez (`make setup`), com suporte a 2FA. O que fica guardado é um
  token exportado (`snapcraft export-login`), em `.credentials/` com
  permissões `600`, validado a cada build e ignorado pelo git.
- **Assinatura não-interativa sem expor a chave.** A passphrase é injetada
  no `gpg-agent` (`gpg-preset-passphrase`) apenas durante a sessão de build;
  a chave privada nunca sai de `~/.snap/gnupg`.
- **Developer-id sempre correto.** `authority-id`/`brand-id` são obtidos de
  `snapcraft whoami` no momento do build, eliminando a classe de erros de
  assinatura por IDs desatualizados nos JSON.
- **Rastreabilidade.** Cada imagem é acompanhada de `SHA256SUMS` e
  `build-info.txt`; cada execução gera um log em `workspace/logs/`.
- **Reversibilidade.** A injeção do netplan no `gadget.yaml` é desfeita
  automaticamente após o build (mesmo em caso de erro), mantendo o
  repositório do gadget limpo.

## Resolução de problemas

| Sintoma | Causa provável / solução |
|---|---|
| `Sem credenciais válidas` | Token expirou → `make setup` de novo |
| `cannot sign assertion ... key not found` | `KEY_NAME` no `.env` difere da chave criada → `snap keys` para listar |
| `snap sign` pede passphrase | `KEY_PASSPHRASE` errada no `.env`, ou `gpg-agent` reiniciado → volta a correr o build |
| register-key falha | Termos do developer não aceites em dashboard.snapcraft.io |
| Wi-Fi não configurado na imagem | `network.yaml` ainda com valores de exemplo (o pipeline avisa e ignora) |
| Snapd não arranca no container | `make rebuild`; confirmar que o Docker corre com cgroups v2 |

## Nota sobre a versão anterior

Os scripts `workspace/build-image.sh` e `workspace/check-dependency.sh`
correspondem à primeira iteração (V1) e estão obsoletos — mantidos apenas
como referência histórica para a dissertação. As principais diferenças
desta versão: login sem password em texto plano (e compatível com 2FA),
criação/registo de chave totalmente automatizados, templates de assertions
renderizados com o developer-id real, cache do gadget, outputs versionados
com checksums e proveniência, e diagnóstico (`doctor`).
