# Ubuntu Core Image Builder — Guia 🏗️

Guia e pipeline de referência para automatizar a criação de imagens
**Ubuntu Core** personalizadas (exemplo: Raspberry Pi), com assinatura
criptográfica, utilizador de sistema pré-configurado e CI/CD opcional.

> ⚠️ **Antes de usar: clona e torna PRIVADO.**
> Este repositório é um guia público e por isso todos os valores
> sensíveis estão marcados com `XXXXX`. A tua cópia vai conter dados
> pessoais (email, IDs de developer, chaves SSH públicas, configuração
> de rede) e, se ativares o CI/CD, secrets da tua conta Ubuntu One —
> **usa-a sempre como repositório privado**:
>
> ```bash
> gh repo create o-teu-builder --private --clone
> # copia o conteúdo deste guia para lá e trabalha no privado
> ```

Todo o processo — autenticação, gestão de chaves, geração e assinatura
das assertions (`model` e `system-user`), build do gadget e geração da
imagem — é orquestrado por um único script com subcomandos, dentro de
um container Docker reprodutível.

## Arquitetura

```
├── Makefile                  # comandos de conveniência (host)
├── Dockerfile                # ambiente de build (systemd + snapd)
├── docker-compose.yaml
├── TUTORIAL.md               # passo-a-passo + CI/CD + segurança
└── workspace/                # montado em /workspace no container
    ├── pipeline.sh           # orquestrador: setup | build | doctor | clean | all
    ├── lib/common.sh         # logging, .env, gpg, credenciais
    ├── config/
    │   ├── .env.example      # → copiar para workspace/.env e preencher
    │   ├── model.template.json
    │   ├── system-user.template.json
    │   └── ssh-authorized-keys.example
    ├── network.yaml          # (opcional) netplan injetado no gadget
    ├── pi-gadget/            # submodule: fonte do gadget snap
    ├── build/                # artefactos intermédios (gerado)
    ├── output/<run-id>/      # imagens + SHA256SUMS + build-info.txt
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

Pré-requisitos: Docker + Compose, make, conta [Ubuntu One](https://login.ubuntu.com)
com os termos de developer aceites em [dashboard.snapcraft.io](https://dashboard.snapcraft.io).

```bash
# 1. Clonar (com o submodule do gadget!)
git clone --recurse-submodules <URL-DA-TUA-CÓPIA-PRIVADA>
cd <o-teu-builder>

# 2. Configuração
cp workspace/config/.env.example workspace/.env                        # preencher
cp workspace/config/ssh-authorized-keys.example workspace/config/ssh-authorized-keys
#    → cola a tua chave SSH pública (SEM ela não há acesso ao dispositivo!)

# 3. Ambiente
make up

# 4. Setup inicial — UMA vez (login Ubuntu One + chave de assinatura)
make setup

# 5. Build
make doctor && make image
```

A imagem fica em `workspace/output/<data>_<modelo>/` (atalho
`workspace/output/latest/`) com `SHA256SUMS` e `build-info.txt`.

```bash
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
| `make clean` | Remove artefactos intermédios |
| `make shell` | Bash dentro do container |

## Configuração (`workspace/.env`)

| Variável | Descrição | Omissão |
|---|---|---|
| `KEY_NAME` | Nome da chave de assinatura | *(obrigatório)* |
| `KEY_PASSPHRASE` | Passphrase; vazio = sem passphrase (CI) | vazio |
| `MODEL_NAME` | Nome do modelo (assertion `model`) | `rpi5-gateway` |
| `ARCHITECTURE` / `BASE` / `GRADE` | Parâmetros do modelo | `arm64` / `core24` / `dangerous` |
| `SYSTEM_USER_EMAIL` / `_USERNAME` / `_FULLNAME` | Utilizador criado no 1º arranque | *(obrigatório)* |
| `SYSTEM_USER_VALID_YEARS` | Validade da asserção system-user | `10` |
| `COMPRESS_IMAGE` | `true` = comprime a imagem com xz | `false` |

Os snaps incluídos na imagem definem-se em
`workspace/config/model.template.json` (substitui a entrada `XXXXX`
pelo teu snap de aplicação). Os campos de identidade (`authority-id`,
`brand-id`, `timestamp`, …) são preenchidos automaticamente pelo
pipeline a partir de `snapcraft whoami` — **nunca é preciso editá-los
à mão**.

## CI/CD e segurança

O CI/CD (GitHub Actions → releases com as imagens) **não vem ativado
neste guia** — porque só faz sentido na tua cópia privada, com os teus
secrets. O [TUTORIAL.md](TUTORIAL.md) explica passo a passo:

- como montar o workflow completo (o YAML está lá pronto a copiar);
- que secrets criar e como (token da Store, chave GPG, dados pessoais);
- **os pontos críticos de segurança** — onde vive cada segredo, o que
  nunca pode entrar no git, backup da chave de assinatura, rotação de
  credenciais.

## Decisões de segurança do pipeline

- **Sem passwords em ficheiros.** O login no Ubuntu One é interativo e
  feito uma única vez (`make setup`), com suporte a 2FA. Só o token
  exportado fica guardado (`.credentials/`, chmod 600, gitignored).
- **Assinatura não-interativa sem expor a chave.** A passphrase é
  injetada no `gpg-agent` apenas durante a sessão de build; a chave
  privada nunca sai de `~/.snap/gnupg`.
- **Developer-id sempre correto.** `authority-id`/`brand-id` vêm de
  `snapcraft whoami` no momento do build.
- **Dados pessoais fora do git.** `.env`, `ssh-authorized-keys` e
  `network.yaml` (Wi-Fi!) são gitignored; os exemplos versionados só
  têm placeholders.
- **Rastreabilidade.** Cada imagem sai com `SHA256SUMS` e
  `build-info.txt`; cada execução gera log em `workspace/logs/`.

## Resolução de problemas

| Sintoma | Causa provável / solução |
|---|---|
| `Sem credenciais válidas` | Token expirou → `make setup` de novo |
| `cannot sign assertion ... key not found` | `KEY_NAME` no `.env` difere da chave criada → `snap keys` |
| `snap sign` pede passphrase | `KEY_PASSPHRASE` errada, ou gpg-agent reiniciado → repete o build |
| register-key falha | Termos do developer não aceites em dashboard.snapcraft.io |
| Wi-Fi não configurado na imagem | `network.yaml` vazio ou com valores de exemplo (o pipeline avisa) |
| Snapd não arranca no container | `make rebuild`; confirmar cgroups v2 no Docker |
| Gadget falha com ficheiro em falta | Vê se o teu gadget precisa de binários externos (não versionados) |
