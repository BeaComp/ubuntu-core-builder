# Tutorial — from clone to published image 🚀

Complete guide: clone, configure, build Ubuntu Core images locally and
(optionally) set up CI/CD with GitHub Actions to publish every version
as a GitHub Release. At the end, the **critical security points**.

> ⚠️ Always work in a **private copy** of this repository — your
> version will hold personal data and secrets (see the README warning).

---

## Part 1 — Local build

### 1.1 Prerequisites

| Tool | Purpose | Install (Ubuntu) |
|---|---|---|
| git | clone the repository | `sudo apt install git` |
| Docker + Compose | isolated build environment | [docs.docker.com](https://docs.docker.com/engine/install/ubuntu/) |
| make | convenience commands | `sudo apt install make` |
| GitHub CLI (`gh`) | CI secrets and releases | [cli.github.com](https://cli.github.com) |

Plus an **Ubuntu One** account with the developer terms accepted at
[dashboard.snapcraft.io](https://dashboard.snapcraft.io).

### 1.2 Clone (with the submodule!)

The gadget is a submodule — a plain clone leaves the folder empty:

```bash
git clone --recurse-submodules <URL-OF-YOUR-PRIVATE-COPY>
cd <your-builder>
# already cloned without --recurse-submodules? → git submodule update --init
```

If your gadget needs external binaries that are not versioned (e.g. a
remote-management agent), put them in the location expected by the
gadget's `snapcraft.yaml` now — see section 2.4 for a clean way to
distribute them.

### 1.3 Configure

```bash
cp workspace/config/.env.example workspace/.env
nano workspace/.env    # KEY_NAME, system-user data, etc.

cp workspace/config/ssh-authorized-keys.example workspace/config/ssh-authorized-keys
nano workspace/config/ssh-authorized-keys   # paste your PUBLIC key
```

⚠️ Ubuntu Core has **no password login** — without a valid SSH key in
`ssh-authorized-keys` there is no way to access the device.

(Optional) Pre-configured Wi-Fi: fill `workspace/network.yaml` with
netplan (`network:` at the top). This file is gitignored — **never**
remove it from there: it contains your network password.

### 1.4 Start and authenticate

```bash
make up      # builds and starts the container (first time is slow)
make setup   # interactive, once: Ubuntu One login (2FA ok) +
             # signing key creation and registration
```

Your password is never stored — only a revocable token
(`workspace/.credentials/`, chmod 600, gitignored).

**New machine with an existing key?** You cannot register another key
with the same name. Restore your backup BEFORE `make setup`:

```bash
docker exec -i ubuntu-core-builder sh -c \
  'mkdir -p /root/.snap/gnupg && chmod 700 /root/.snap/gnupg && \
   gpg --homedir /root/.snap/gnupg --import' < your-key-backup.asc
```

### 1.5 Build

```bash
make doctor    # diagnostics: everything ✔?
make image     # full non-interactive build
```

Result in `workspace/output/latest/`:

```bash
sudo dd if=workspace/output/latest/pi.img of=/dev/sdX bs=32M status=progress
# double-check /dev/sdX with "lsblk" — dd is unforgiving!
```

---

## Part 2 — Setting up CI/CD (GitHub Actions)

The goal: `git tag v1.0.0 && git push origin v1.0.0` → GitHub builds
the image and publishes it as a **Release** with checksums and
provenance. Only do this in a **private** repository (the secrets grant
access to your developer account, and the images are visible to anyone
who can see the repository).

### 2.1 Create the secrets

| Secret | Content | How to obtain |
|---|---|---|
| `SNAPCRAFT_STORE_CREDENTIALS` | Snap Store token | `docker exec ubuntu-core-builder cat /workspace/.credentials/snapcraft-store.txt` |
| `SNAP_SIGNING_KEY` | private GPG key (armored) | `docker exec ubuntu-core-builder gpg --homedir /root/.snap/gnupg --export-secret-keys --armor <KEY_NAME>` |
| `KEY_NAME` | signing key name | your `.env` |
| `SYSTEM_USER_EMAIL` | Ubuntu One email | your `.env` |
| `SYSTEM_USER_USERNAME` | system-user username | your `.env` |
| `SYSTEM_USER_FULLNAME` | full name | your `.env` |
| `SSH_AUTHORIZED_KEYS` | public SSH keys (one per line) | `config/ssh-authorized-keys` |
| `KEY_PASSPHRASE` | (optional) key passphrase | your `.env` |

With `gh` authenticated, inside your repository:

```bash
gh secret set SECRET_NAME   # paste the value, or use --body / stdin
```

This way **no personal data lives in git** — not even in the private
copy: the workflow builds the `.env` from secrets at run time.

### 2.2 The workflow

Create `.github/workflows/build-image.yml` with the content below
(replace `<YOUR-USER>/<YOUR-REPO>` if you use the external-binary step;
otherwise delete that step):

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
      - name: Checkout (including the gadget)
        uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: Install tools
        run: |
          sudo snap install snapcraft --classic
          sudo snap install ubuntu-image --classic
          sudo snap install lxd
          sudo lxd init --auto
          # Docker preinstalled on the runner sets FORWARD to DROP,
          # cutting network access for snapcraft's LXD containers
          sudo iptables -I DOCKER-USER -i lxdbr0 -j ACCEPT || true
          sudo iptables -I DOCKER-USER -o lxdbr0 -j ACCEPT || true
          sudo curl -fsSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
            -o /usr/local/bin/yq
          sudo chmod +x /usr/local/bin/yq

      - name: Configure authentication (Store + signing key)
        env:
          STORE_CREDENTIALS: ${{ secrets.SNAPCRAFT_STORE_CREDENTIALS }}
          SIGNING_KEY: ${{ secrets.SNAP_SIGNING_KEY }}
        run: |
          test -n "$STORE_CREDENTIALS" || { echo "::error::Missing secret SNAPCRAFT_STORE_CREDENTIALS"; exit 1; }
          test -n "$SIGNING_KEY"       || { echo "::error::Missing secret SNAP_SIGNING_KEY"; exit 1; }
          install -d -m 700 workspace/.credentials
          printf '%s' "$STORE_CREDENTIALS" > workspace/.credentials/snapcraft-store.txt
          chmod 600 workspace/.credentials/snapcraft-store.txt
          # The pipeline runs as root → snap keyring at /root/.snap/gnupg
          sudo install -d -m 700 /root/.snap/gnupg
          printf '%s' "$SIGNING_KEY" | sudo env GNUPGHOME=/root/.snap/gnupg gpg --batch --import

      - name: (Optional) Fetch external gadget binaries
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          # Example: binary distributed as an asset of a dedicated release
          gh release download <RELEASE-TAG> \
            --repo <YOUR-USER>/<YOUR-REPO> \
            --pattern <binary> \
            --output workspace/pi-gadget/<expected-path>/<binary>
          chmod +x workspace/pi-gadget/<expected-path>/<binary>

      - name: Prepare .env and SSH keys (from secrets)
        env:
          KEY_NAME: ${{ secrets.KEY_NAME }}
          KEY_PASSPHRASE: ${{ secrets.KEY_PASSPHRASE }}
          SYSTEM_USER_EMAIL: ${{ secrets.SYSTEM_USER_EMAIL }}
          SYSTEM_USER_USERNAME: ${{ secrets.SYSTEM_USER_USERNAME }}
          SYSTEM_USER_FULLNAME: ${{ secrets.SYSTEM_USER_FULLNAME }}
          SSH_AUTHORIZED_KEYS: ${{ secrets.SSH_AUTHORIZED_KEYS }}
        run: |
          for v in KEY_NAME SYSTEM_USER_EMAIL SYSTEM_USER_USERNAME SSH_AUTHORIZED_KEYS; do
            test -n "${!v}" || { echo "::error::Missing secret $v"; exit 1; }
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
            # Release assets are capped at 2 GB → compression is mandatory
            echo "COMPRESS_IMAGE=true"
          } > workspace/.env
          printf '%s\n' "$SSH_AUTHORIZED_KEYS" > workspace/config/ssh-authorized-keys

      - name: Build the image
        run: |
          # HOME=/root: under sudo, snapd resolves the keyring via the
          # real user (runner); force the same dir used by the import
          sudo -E env "PATH=$PATH" HOME=/root \
            WORKSPACE="$GITHUB_WORKSPACE/workspace" \
            ./workspace/pipeline.sh build
          OUT=$(readlink -f workspace/output/latest)
          sudo chmod -R a+r "$OUT"
          echo "OUT=$OUT" >> "$GITHUB_ENV"

      - name: Publish GitHub Release
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

      - name: Store artifact (manual run)
        if: "!startsWith(github.ref, 'refs/tags/')"
        uses: actions/upload-artifact@v4
        with:
          name: ubuntu-core-image
          path: ${{ env.OUT }}
          retention-days: 7
```

### 2.3 Publish a version

```bash
git tag v1.0.0
git push origin v1.0.0
# ≈5 min later: .../releases/tag/v1.0.0 with pi.img.xz + SHA256SUMS
```

For a test build without a release: Actions → build-image →
**Run workflow** (result is kept as an artifact for 7 days).

Verify the integrity of anything you download:

```bash
sha256sum -c SHA256SUMS
xz -dc pi.img.xz | sudo dd of=/dev/sdX bs=32M status=progress
```

### 2.4 External gadget binaries

If your gadget needs binaries that must not enter git (agents,
firmware, blobs), the clean pattern is publishing them **once** as an
asset of a dedicated release:

```bash
gh release create my-binary --latest=false --title "..." path/to/binary
```

…and downloading them in CI with `gh release download` (the optional
workflow step above). Careful: in a public repository, release assets
are public — binaries or config files carrying identifiers/credentials
of your environment must live in a **private** repository's release
instead (the workflow's `github.token` can download assets from its own
repository, even when private).

### 2.5 The gadget is a submodule

CI uses **the gadget commit pinned by the main repository**, not your
working tree:

```bash
cd workspace/pi-gadget
# ... commit + push in the gadget repo ...
cd ../..
git add workspace/pi-gadget && git commit -m "bump gadget" && git push
```

---

## Part 3 — Critical security points ⚠️

### P1. The signing key: backup is mandatory

The private GPG key (signs `model` and `system-user`) lives in
`/root/.snap/gnupg` **inside the container** — which is ephemeral:
`docker compose down` or `make rebuild` **destroy it**. The GitHub
secret cannot be read back (write-only). Back it up now:

```bash
docker exec ubuntu-core-builder gpg --homedir /root/.snap/gnupg \
  --export-secret-keys --armor <KEY_NAME> > key-backup.asc
chmod 600 key-backup.asc    # store OUTSIDE any git repository
```

Whoever holds this key can sign images and system-users **valid in
your name**. Compromised? Remove it at dashboard.snapcraft.io and
rotate (new `KEY_NAME` + `make setup` + redo the secrets).

### P2. The Store token is your developer account

It grants publisher-account access (registering keys, publishing
snaps). It expires after ≈1 year → `make setup` + redo the secret.
Suspected leak → revoke sessions at login.ubuntu.com. The **Ubuntu One
password is never stored** — login is interactive, with 2FA.

### P3. Private repository, always

With a private repository: secrets, images (releases/artifacts) and
history are only visible to people you authorize. GitHub Secrets are
encrypted, masked in logs and not handed to fork workflows — but the
**assets and code of a public repo belong to everyone**. Remember:
whatever entered git once stays in the **history** even after deletion
— a committed secret is a compromised secret (rotate it).

### P4. Personal data only in secrets and gitignored files

In this pipeline, `.env`, `ssh-authorized-keys` and `network.yaml` are
gitignored, and CI receives everything via secrets. Before each commit:
`git status` — if one of those files shows up, something is wrong.

### P5. `grade: dangerous` is for development

It accepts unasserted snaps. For production devices use `GRADE=signed`
— the image then requires everything to be signed.

### P6. Device access = private SSH key

Ubuntu Core only accepts SSH by key (the system-user's public keys +
the Ubuntu One account ones). Protect the corresponding private keys
(`~/.ssh/id_*`); on a new machine, generate a new pair and add the
public key — do not copy private keys between machines.

### P7. Remote-management/agent identifiers are credentials

Agent configuration files (e.g. a MeshCentral `.msh` carrying
`MeshID`/`ServerID`/server URL) work as **enrollment credentials**:
whoever holds them can register rogue devices on your server. Never
publish them; distribute via secrets or a private repository, and watch
for unknown devices.

### Summary — where each secret lives

| Secret | Local | GitHub | Risk if leaked |
|---|---|---|---|
| Private GPG key | container + your backup | secret (write-only) | signing images in your name |
| Snap Store token | `.credentials/` (600, gitignored) | secret | control of the publisher account |
| Ubuntu One password | **never stored** | — | (protected by 2FA) |
| Personal data (email, SSH pub, …) | local `.env` (gitignored) | secrets | doxxing / spam |
| Wi-Fi password | local `network.yaml` (gitignored) | — | access to your network |
| Private SSH key | your machine's `~/.ssh/` | — | access to the devices |
