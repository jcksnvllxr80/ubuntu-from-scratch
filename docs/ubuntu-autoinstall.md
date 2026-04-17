# Ubuntu Autoinstall — Custom Stripped-Down Server Image

> **Goal:** Fully automated, minimal Ubuntu 22.04 server install. Autoinstall builds a golden VM.
> That VM is sysprep'd, compressed, and stored. A factory utility transfers and installs it
> directly onto target hardware. Customer-specific packages arrive post-deployment via nightly apt.

---

## Full Pipeline

```
 1. autoinstall         2. firstboot          3. sysprep            4. compress
 ─────────────────      ─────────────────     ─────────────────     ─────────────────
 unattended install  →  baseline config    →  clean machine     →  qcow2 → raw.gz
 on local VM            SSH harden             state (keys,          stored in
 pulls base pkgs        configure apt          machine-id,           artifact store
                                               logs, cache)

 5. factory utility     6. deployed           7. nightly apt
 ─────────────────      ─────────────────     ─────────────────
 connects to server  →  server reboots     →  customer packages
 transfers image        into golden state      arrive via
 dd's to disk           network reaches        unattended-upgrades
 reboots                pkg store              postinst applies
                                               customer config
```

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Directory Layout](#directory-layout)
3. [user-data YAML](#user-data-yaml)
4. [Package Repo](#package-repo)
5. [First Boot](#first-boot)
6. [Sysprep — Golden Image Prep](#sysprep--golden-image-prep)
7. [Compress and Store](#compress-and-store)
8. [Factory Utility](#factory-utility)
9. [Nightly apt Updates](#nightly-apt-updates)
10. [Verify](#verify)
11. [Next Steps](#next-steps)

---

## Prerequisites

### Build Machine (Ubuntu/Debian recommended)

```bash
apt-get install -y \
  dpkg-dev \       # generates Packages index for apt repo
  apt-utils \      # apt-ftparchive
  genisoimage \    # builds the cidata ISO
  awscli \         # syncs repo and image to artifact store
  whois \          # mkpasswd for password hashing
  qemu-system \    # runs the autoinstall VM
  curl
```

### Artifact Store

Internal store — S3 or self-hosted (Nexus, nginx, etc.). Stores both the package repo and the
compressed golden image. Must be reachable from the build machine and from deployed edge servers
for nightly apt updates.

| Resource | Requirement |
|---|---|
| Artifact store | Reachable from build machine and from deployed edge servers |
| Write credentials | For pushing packages and compressed image |
| Read credentials | Baked into image for unattended nightly apt |

### Your Assets

| Asset | Notes |
|---|---|
| SSH public key | `ssh-keygen -t ed25519` — goes into `authorized-keys` in user-data |
| Hashed password | `mkpasswd -m sha-512 yourpassword` — paste `$6$...` into user-data |
| Ubuntu 22.04 ISO | `ubuntu-22.04.3-live-server-amd64.iso` from releases.ubuntu.com |
| Base `.deb` packages | Standard tooling for all deployments |

> **Never put a plaintext password in user-data.** Always use the SHA-512 hash (`$6$` prefix).

---

## Directory Layout

```
ubuntu-custom/
├── autoinstall/                  # burned into cidata ISO
│   ├── user-data                 # autoinstall YAML — identical for all deployments
│   └── meta-data                 # required but near-empty
│
├── firstboot/                    # copied into target by late-commands
│   ├── firstboot.sh              # one-shot: hardens SSH, configures nightly apt
│   └── services/
│       └── firstboot.service     # systemd unit — runs script, disables self
│
├── sysprep/
│   └── sysprep.sh                # cleans machine-specific state before imaging
│
├── factory/
│   └── install.sh                # runs on target server — dd's image to disk, reboots
│
└── repo/                         # synced to artifact store, NOT in the ISO
    ├── dists/jammy/main/binary-amd64/
    │   ├── Packages
    │   └── Packages.gz
    └── pool/main/base/
        └── base-tooling_1.0_amd64.deb
```

**Create the skeleton:**

```bash
mkdir -p ubuntu-custom/{autoinstall,firstboot/services,sysprep,factory}
mkdir -p ubuntu-custom/repo/dists/jammy/main/binary-amd64
mkdir -p ubuntu-custom/repo/pool/main/base

cd ubuntu-custom
```

---

## user-data YAML

Drives the unattended install on the build VM. Identical for all deployments.

### Section Reference

| Section | What It Does |
|---|---|
| `locale` / `keyboard` | Base system locale and keymap |
| `network` | DHCP on eth0 at install time |
| `storage` | LVM layout — use `name: direct` to skip LVM |
| `identity` | Baseline hostname, username, SHA-512 hashed password |
| `ssh` | Installs openssh-server, injects pubkey, disables password auth |
| `packages` | Minimal base packages — includes `unattended-upgrades` for nightly apt |
| `apt.sources` | Points at internal artifact store — baked in at build time |
| `late-commands` | Strips bloat, copies firstboot files, enables firstboot.service |

### Full YAML

```yaml
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us

  network:
    network:
      version: 2
      ethernets:
        eth0:
          dhcp4: true

  storage:
    layout:
      name: lvm          # or 'direct' to skip LVM

  identity:
    hostname: edge-server
    username: admin
    password: "$6$rounds=4096$salt$hash"   # mkpasswd -m sha-512

  ssh:
    install-server: true
    authorized-keys:
      - "ssh-ed25519 AAAA... your-key"
    allow-pw: false

  packages:
    - curl
    - wget
    - htop
    - ca-certificates
    - unattended-upgrades

  apt:
    sources:
      internal-pkg-store:
        source: "deb [trusted=yes] https://your-artifact-store/repo jammy main"

  late-commands:
    - curtin in-target --target=/target -- systemctl disable snapd
    - curtin in-target --target=/target -- apt-get purge -y snapd ubuntu-advantage-tools
    - curtin in-target --target=/target -- apt-get autoremove -y
    - cp /cdrom/firstboot/firstboot.sh /target/usr/local/sbin/firstboot.sh
    - chmod +x /target/usr/local/sbin/firstboot.sh
    - cp /cdrom/firstboot/services/firstboot.service /target/etc/systemd/system/firstboot.service
    - curtin in-target --target=/target -- systemctl enable firstboot.service

  user-data:
    disable_root: true
```

### meta-data

```yaml
instance-id: edge-server-001
```

---

## Package Repo

Hosted on your internal artifact store. Serves base tooling during autoinstall and firstboot.
Customer-specific packages are published here and delivered to deployed servers via nightly apt.

### Build and Publish

```bash
cp base-tooling_1.0_amd64.deb repo/pool/main/base/

cd ubuntu-custom/repo
dpkg-scanpackages pool/main/ > dists/jammy/main/binary-amd64/Packages
gzip -k dists/jammy/main/binary-amd64/Packages

aws s3 sync . s3://your-artifact-store/repo --acl public-read

# verify
curl -I https://your-artifact-store/repo/dists/jammy/main/binary-amd64/Packages
```

### Publishing a New or Updated Package

```bash
cp yourpkg_1.1_amd64.deb repo/pool/main/base/
cd ubuntu-custom/repo
dpkg-scanpackages pool/main/ > dists/jammy/main/binary-amd64/Packages
gzip -k dists/jammy/main/binary-amd64/Packages
aws s3 sync . s3://your-artifact-store/repo --acl public-read
```

---

## First Boot

Runs once on the build VM after autoinstall completes. Handles baseline hardening and configures
unattended-upgrades. Disables itself on completion.

### firstboot.sh

```bash
#!/bin/bash
set -euo pipefail
LOG=/var/log/firstboot.log
exec > >(tee -a "$LOG") 2>&1

echo "[firstboot] Starting $(date)"

# ── Install base packages ─────────────────────────────────────
apt-get update -qq
apt-get install -y base-tooling

# ── Harden SSH ────────────────────────────────────────────────
sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd

# ── Configure unattended-upgrades for nightly apt ─────────────
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Allowed-Origins {
    "your-artifact-store:jammy";
};
Unattended-Upgrade::Automatic-Reboot "false";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

systemctl enable unattended-upgrades
systemctl start unattended-upgrades

# ── Disable self ───────────────────────────────────────────────
systemctl disable firstboot.service

echo "[firstboot] Done $(date)"
```

### firstboot.service

```ini
[Unit]
Description=First boot provisioning
After=network-online.target
Wants=network-online.target
ConditionPathExists=/usr/local/sbin/firstboot.sh

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/firstboot.sh
RemainAfterExit=yes
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
```

---

## Sysprep — Golden Image Prep

After firstboot completes on the VM, clean all machine-specific state before imaging.
**This must be done before compressing.** Every server deployed from the image needs to come
up clean and generate its own identity on first boot.

> **Shut the VM down cleanly after sysprep. Do not boot it again before imaging.**
> Booting after sysprep regenerates the state you just cleaned.

### sysprep.sh

```bash
#!/bin/bash
# Run inside the VM before shutdown. Do not boot again after this.
set -euo pipefail

echo "[sysprep] Starting $(date)"

# ── Remove SSH host keys — regenerated on first boot ──────────
rm -f /etc/ssh/ssh_host_*

# ── Reset machine-id — must be unique per deployment ──────────
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

# ── Clear logs ────────────────────────────────────────────────
find /var/log -type f -exec truncate -s 0 {} \;

# ── Clear apt cache ───────────────────────────────────────────
apt-get clean

# ── Clear shell history ───────────────────────────────────────
unset HISTFILE
rm -f /root/.bash_history
rm -f /home/*/.bash_history

# ── Clear tmp ─────────────────────────────────────────────────
rm -rf /tmp/* /var/tmp/*

echo "[sysprep] Done — shut down now, do not reboot"
```

```bash
# Run sysprep then immediately shut down
sudo bash sysprep.sh && sudo shutdown -h now
```

### What systemd does on first boot after sysprep

When a server is deployed from the sysprep'd image and boots for the first time:
- New SSH host keys are generated automatically by `ssh-keygen` via the `ssh` service
- A new `machine-id` is generated automatically by `systemd-machine-id-setup`
- Each deployed server ends up with a unique identity

---

## Compress and Store

After the VM is shut down cleanly post-sysprep, convert and compress the disk image.

```bash
# 1. Convert qcow2 to raw
qemu-img convert -f qcow2 -O raw disk.img disk.raw

# 2. Compress (xz gives best ratio, gzip is faster)
xz -T 0 -v disk.raw              # produces disk.raw.xz
# or
gzip -v disk.raw                  # produces disk.raw.gz

# 3. Push to artifact store
aws s3 cp disk.raw.xz s3://your-artifact-store/images/edge-server-latest.raw.xz

# 4. Verify
aws s3 ls s3://your-artifact-store/images/
```

> `xz -T 0` uses all available CPU threads. On a typical Ubuntu server image expect
> ~2-4GB compressed down to ~500MB-1GB depending on content.

---

## Factory Utility

> ⚠ **TBD — approach is defined, implementation details are not yet finalised.**

### What Is Known

A factory workstation utility connects to the target server, transfers the compressed image
and install script, and executes the install remotely. The install script decompresses the
image and `dd`'s it directly to the target disk, then reboots.

**Confirmed flow:**

```
factory workstation
        ↓
  connects to target server (SSH)
        ↓
  transfers compressed image + install.sh (SCP / rsync)
        ↓
  executes install.sh remotely
        ↓
  install.sh: decompress → dd to disk → reboot
        ↓
  server boots into golden state
```

### install.sh (runs on target server)

```bash
#!/bin/bash
# Executed remotely by the factory utility.
# Writes the golden image to the target disk and reboots.
set -euo pipefail

IMAGE_URL="https://your-artifact-store/images/edge-server-latest.raw.xz"
TARGET_DISK="/dev/sda"       # ⚠ TBD — confirm target disk per hardware platform

echo "[install] Downloading image..."
curl -fSL "$IMAGE_URL" -o /tmp/image.raw.xz

echo "[install] Writing to $TARGET_DISK..."
xz -dc /tmp/image.raw.xz | dd of="$TARGET_DISK" bs=4M status=progress conv=fsync

echo "[install] Rebooting..."
reboot
```

### Factory Workstation Script (transfers and triggers install)

```bash
#!/bin/bash
# Runs on the factory workstation.
TARGET_HOST="$1"              # e.g. 192.168.1.50
SSH_KEY="~/.ssh/factory-key"

echo "[factory] Transferring install script..."
scp -i "$SSH_KEY" factory/install.sh admin@"$TARGET_HOST":/tmp/install.sh

echo "[factory] Executing install..."
ssh -i "$SSH_KEY" admin@"$TARGET_HOST" "sudo bash /tmp/install.sh"
```

Usage:

```bash
bash factory-provision.sh 192.168.1.50
```

### Open Questions

| # | Question | Impact |
|---|---|---|
| 1 | What OS is running on the target server when the factory utility connects? | Determines what environment install.sh runs in |
| 2 | How does the target server boot into that environment? | USB live Linux, PXE, vendor factory OS, iDRAC? |
| 3 | Is the target disk always the same device path across all hardware? | Affects `TARGET_DISK` in install.sh — may need auto-detection |
| 4 | Should the factory utility be a shell script, Python tool, or something else? | Affects how it's distributed and run on the workstation |

---

## Nightly apt Updates

`unattended-upgrades` is configured by firstboot. This is how customer-specific packages reach
deployed servers — no manual intervention required.

```
new customer .deb published to artifact store
        ↓
nightly apt run on deployed server
        ↓
package installed → postinst applies customer-specific config
```

**Manual trigger:**

```bash
unattended-upgrade --debug
# or
apt-get update && apt-get upgrade -y
```

**Check last run:**

```bash
tail -30 /var/log/unattended-upgrades/unattended-upgrades.log
```

> `Automatic-Reboot` is off. Handle reboots in postinst or via fleet management if required.

---

## Verify

### VM Build (after firstboot completes)

```bash
ssh -i ~/.ssh/your-key admin@VM_IP

systemctl status firstboot.service
systemctl is-enabled firstboot.service    # expect: disabled
cat /var/log/firstboot.log
grep -E "PermitRootLogin|PasswordAuthentication" /etc/ssh/sshd_config
dpkg -l snapd 2>&1 | grep -E "^ii|not installed"
dpkg -l base-tooling
apt-get update
systemctl status unattended-upgrades
```

### After Factory Install (deployed server first boot)

```bash
ssh -i ~/.ssh/your-key admin@SERVER_IP

# Confirm machine-id is unique (not blank, not matching build VM)
cat /etc/machine-id

# Confirm SSH host keys were regenerated
ls -la /etc/ssh/ssh_host_*

# Confirm network reaches artifact store
apt-get update

# Confirm unattended-upgrades is running
systemctl status unattended-upgrades
```

### After First Nightly apt Run

```bash
dpkg -l customer-pkg-name
tail -30 /var/log/unattended-upgrades/unattended-upgrades.log
```

---

## Next Steps

| Topic | Notes |
|---|---|
| Factory utility implementation | Decide: shell script, Python, or a more formal provisioning tool. Resolve open questions in the Factory Utility section. |
| Target disk detection | `install.sh` currently hardcodes `/dev/sda` — may need auto-detection logic for varied hardware |
| GPG-sign the repo | Replace `trusted=yes` — use `reprepro` for signing, indexing, versioning |
| Customer `.deb` postinst | All customer-specific setup runs here — hostname, service config, hardware interface params |
| Repo auth | Bake a read-only credential into the image for unattended apt auth against a private store |
| Custom partition layout | Replace `layout: lvm` with explicit partition spec in `storage:` if needed |

### Customer `.deb` postinst Pattern

```bash
#!/bin/bash
# DEBIAN/postinst
set -e

hostnamectl set-hostname "customer-site-name"
cp /usr/share/customer-pkg/config/service.conf /etc/myapp/service.conf
systemctl enable myapp.service
systemctl restart myapp.service
```

---

*Ubuntu 22.04 LTS · Jammy · autoinstall v1 · cloud-init · edge deployment*
