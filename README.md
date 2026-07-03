# Ubuntu Core Image Builder — Guide 🏗️

Reference guide and pipeline for automating the creation of custom
**Ubuntu Core** images (e.g. for Raspberry Pi), with cryptographic
signing, a pre-configured system user and optional CI/CD.

> ⚠️ **Before using: clone this and make your copy PRIVATE.**
> This repository is a public guide, so every sensitive value is
> masked as `XXXXX`. Your copy will hold personal data (email,
> developer IDs, public SSH keys, network configuration) and, if you
> enable CI/CD, secrets tied to your Ubuntu One account — **always
> work in a private repository**:
>
> ```bash
> gh repo create your-builder --private --clone
> # copy the contents of this guide there and work in the private copy
> ```

The whole process — authentication, key management, generation and
signing of the assertions (`model` and `system-user`), gadget build and
image generation — is orchestrated by a single script with subcommands,
inside a reproducible Docker container.

## Architecture

```
├── Makefile                  # convenience commands (host)
├── Dockerfile                # build environment (systemd + snapd)
├── docker-compose.yaml
├── TUTORIAL.md               # step-by-step + CI/CD + security
└── workspace/                # mounted at /workspace in the container
    ├── pipeline.sh           # orchestrator: setup | build | doctor | clean | all
    ├── lib/common.sh         # logging, .env, gpg, credentials
    ├── config/
    │   ├── .env.example      # → copy to workspace/.env and fill in
    │   ├── model.template.json
    │   ├── system-user.template.json
    │   └── ssh-authorized-keys.example
    ├── network.yaml          # (optional) netplan injected into the gadget
    ├── pi-gadget/            # submodule: gadget snap source
    ├── build/                # intermediate artifacts (generated)
    ├── output/<run-id>/      # images + SHA256SUMS + build-info.txt
    ├── logs/                 # one log per run (generated)
    └── .credentials/         # Snap Store token (generated, chmod 600)
```

## Build flow

```
setup (once, interactive)          build (repeatable, non-interactive)
┌────────────────────────┐         ┌─────────────────────────────────┐
│ 1. Ubuntu One login    │         │ 1. render assertions            │
│    (2FA supported)     │         │    developer-id ← whoami        │
│ 2. create GPG key      │  ────▶  │ 2. snap sign (model +           │
│    (RSA 4096, batch)   │         │    system-user --chain)         │
│ 3. register key with   │         │ 3. snapcraft pack (gadget,      │
│    Canonical           │         │    with cache + netplan)        │
└────────────────────────┘         │ 4. ubuntu-image → output/       │
                                   └─────────────────────────────────┘
```

## Quick start

Prerequisites: Docker + Compose, make, an [Ubuntu One](https://login.ubuntu.com)
account with the developer terms accepted at
[dashboard.snapcraft.io](https://dashboard.snapcraft.io).

```bash
# 1. Clone (with the gadget submodule!)
git clone --recurse-submodules <URL-OF-YOUR-PRIVATE-COPY>
cd <your-builder>

# 2. Configuration
cp workspace/config/.env.example workspace/.env                        # fill in
cp workspace/config/ssh-authorized-keys.example workspace/config/ssh-authorized-keys
#    → paste your public SSH key (WITHOUT it there is no device access!)

# 3. Environment
make up

# 4. Initial setup — ONCE (Ubuntu One login + signing key)
make setup

# 5. Build
make doctor && make image
```

The image lands in `workspace/output/<date>_<model>/` (shortcut
`workspace/output/latest/`) together with `SHA256SUMS` and
`build-info.txt`.

```bash
sudo dd if=workspace/output/latest/pi.img of=/dev/sdX bs=32M status=progress
```

## Commands

| Command | Description |
|---|---|
| `make up` / `make down` | Start / stop the container |
| `make setup` | Store login + key creation/registration (interactive, once) |
| `make image` | Full non-interactive build |
| `make gadget` | Build forcing a gadget rebuild |
| `make doctor` | Diagnostics: dependencies, credentials, key, templates |
| `make clean` | Remove intermediate artifacts |
| `make shell` | Bash inside the container |

## Configuration (`workspace/.env`)

| Variable | Description | Default |
|---|---|---|
| `KEY_NAME` | Signing key name | *(required)* |
| `KEY_PASSPHRASE` | Passphrase; empty = no passphrase (CI) | empty |
| `MODEL_NAME` | Model name (`model` assertion) | `rpi5-gateway` |
| `ARCHITECTURE` / `BASE` / `GRADE` | Model parameters | `arm64` / `core24` / `dangerous` |
| `SYSTEM_USER_EMAIL` / `_USERNAME` / `_FULLNAME` | User created on first boot | *(required)* |
| `SYSTEM_USER_VALID_YEARS` | Validity of the system-user assertion | `10` |
| `COMPRESS_IMAGE` | `true` = compress the image with xz | `false` |

The snaps included in the image are defined in
`workspace/config/model.template.json` (replace the `XXXXX` entry with
your application snap). The identity fields (`authority-id`,
`brand-id`, `timestamp`, …) are filled in automatically by the pipeline
from `snapcraft whoami` — **you never edit them by hand**.

## CI/CD and security

CI/CD (GitHub Actions → releases carrying the images) is **not enabled
in this guide** — it only makes sense in your private copy, with your
own secrets. [TUTORIAL.md](TUTORIAL.md) explains step by step:

- how to set up the complete workflow (the YAML is there, ready to copy);
- which secrets to create and how (Store token, GPG key, personal data);
- **the critical security points** — where each secret lives, what must
  never enter git, signing-key backup, credential rotation.

## Security decisions in this pipeline

- **No passwords in files.** The Ubuntu One login is interactive and
  happens once (`make setup`), with 2FA support. Only the exported
  token is stored (`.credentials/`, chmod 600, gitignored).
- **Non-interactive signing without exposing the key.** The passphrase
  is preset into `gpg-agent` only for the build session; the private
  key never leaves `~/.snap/gnupg`.
- **Always-correct developer id.** `authority-id`/`brand-id` come from
  `snapcraft whoami` at build time.
- **Personal data stays out of git.** `.env`, `ssh-authorized-keys` and
  `network.yaml` (Wi-Fi!) are gitignored; the versioned examples only
  contain placeholders.
- **Traceability.** Every image ships with `SHA256SUMS` and
  `build-info.txt`; every run is logged under `workspace/logs/`.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `Sem credenciais válidas` (no valid credentials) | Token expired → `make setup` again |
| `cannot sign assertion ... key not found` | `KEY_NAME` in `.env` differs from the created key → `snap keys` |
| `snap sign` asks for a passphrase | Wrong `KEY_PASSPHRASE`, or gpg-agent restarted → rerun the build |
| register-key fails | Developer terms not accepted at dashboard.snapcraft.io |
| Wi-Fi not configured in the image | `network.yaml` empty or holding example values (the pipeline warns) |
| snapd does not start in the container | `make rebuild`; check Docker runs with cgroups v2 |
| Gadget fails on a missing file | Check whether your gadget needs external (unversioned) binaries |
