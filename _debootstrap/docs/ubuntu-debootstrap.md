# Ubuntu from Scratch via debootstrap — Reference

A full walk-through of what `build.sh` does under the hood for the
**Ubuntu 26.04 LTS** (Resolute Raccoon) build, plus the operational
topics that live alongside it: golden-image flow, sysprep, compression,
and distribution. Counterpart to `_autoinstall/docs/ubuntu-autoinstall.md`.

---

## Contents

1. [Why debootstrap](#why-debootstrap)
2. [Pipeline](#pipeline)
3. [Prerequisites](#prerequisites)
4. [What `build.sh` does, step by step](#what-buildsh-does-step-by-step)
5. [`config/` reference](#config-reference)
6. [First boot](#first-boot)
7. [Golden image — sysprep before you clone](#golden-image--sysprep-before-you-clone)
8. [Compress & store](#compress--store)
9. [Deploy to bare metal](#deploy-to-bare-metal)
10. [Nightly `apt`](#nightly-apt)
11. [Verification](#verification)
12. [Troubleshooting](#troubleshooting)

---

## Why debootstrap

The autoinstall path rides on Canonical's installer: you boot the
live-server ISO, it reads your `user-data`, and Subiquity/curtin carve up
the disk, install packages, and run post-install steps. That's simple,
but it carries two costs:

- you download a ~2 GB ISO even though you throw ~90% of it away
- the install takes 10–20 minutes of Subiquity time every rebuild

`debootstrap` walks around the installer entirely: it pulls a base
package set directly from the Ubuntu archive, unpacks it into a
directory, and then a chroot finishes the system. No ISO, no installer,
no interactive-looking "Continue with autoinstall?" pause. Rebuilds are
~3–5 minutes from clean.

The trade is that you become responsible for the pieces Subiquity
normally handles: partitioning, bootloader install, initramfs, user
creation, network config, machine-id hygiene. `build.sh` bundles those
into one script.

---

## Pipeline

```
┌───────────────┐   ┌───────────────┐   ┌───────────────┐   ┌───────────────┐
│ 01 ROOTFS     │   │ 02 SYSPREP    │   │ 03 STORE      │   │ 04 DEPLOY     │
│ debootstrap   │──▶│ reset host    │──▶│ qcow2/raw.xz  │──▶│ dd / iPXE     │
│ + chroot      │   │ state, clear  │   │ push to       │   │ to target     │
│ builds image  │   │ ssh host keys │   │ artifact store│   │ disk          │
└───────────────┘   └───────────────┘   └───────────────┘   └───────────────┘
```

Only step 01 is automated in this repo. 02–04 are covered here as
reference so the same pipeline can scale beyond a single VM.

---

## Prerequisites

| Need | Why |
|---|---|
| Linux host (or WSL) | `debootstrap`, `losetup`, `chroot` are Linux-only |
| root | loop-mount and chroot need it |
| `debootstrap` | fetches + unpacks base packages |
| `parted` | partitions the raw image |
| `dosfstools` | `mkfs.vfat` for the EFI System Partition |
| VirtualBox | only for the `run-vm.*` scripts |

Install on Ubuntu/WSL:

```bash
sudo apt install -y debootstrap parted dosfstools
```

---

## What `build.sh` does, step by step

### 1. Create a sparse raw image

```bash
truncate -s 8G build/ubuntu.img
```

Sparse means on-disk size stays small until blocks are written. An
8 GiB target is plenty for a minimal server.

### 2. Partition it GPT (ESP + root)

```bash
parted -s build/ubuntu.img mklabel gpt \
  mkpart ESP  fat32 1MiB 513MiB  set 1 esp on \
  mkpart root ext4  513MiB 100%
```

A 512 MiB EFI System Partition is oversized for a single bootloader,
but leaves room for a second kernel / alternative loader if you ever
dual-boot.

### 3. Attach it as a loop device

```bash
LOOP=$(losetup --find --show --partscan build/ubuntu.img)
# /dev/loop7, with /dev/loop7p1 + /dev/loop7p2 appearing because --partscan
```

### 4. Format and mount

```bash
mkfs.vfat -F32 -n ESP  "${LOOP}p1"
mkfs.ext4 -L root      "${LOOP}p2"
mount "${LOOP}p2" /mnt/ufs
mount "${LOOP}p1" /mnt/ufs/boot/efi
```

Labels matter: `fstab` references them, so the same image boots
regardless of the device name (`/dev/sda2`, `/dev/nvme0n1p2`, etc.) the
target firmware gives it.

### 5. Bootstrap a rootfs

```bash
debootstrap --variant=minbase \
  --include=linux-generic,grub-efi-amd64,shim-signed,systemd-sysv,openssh-server,...
  resolute /mnt/ufs http://archive.ubuntu.com/ubuntu
```

`--variant=minbase` produces a ~150 MB rootfs (no `Priority: important`
packages). `--include=` adds the kernel, bootloader, and everything from
`config/packages.list` in one pass.

### 6. Bind pseudo-filesystems into the chroot

```bash
for d in dev dev/pts proc sys run; do
  mount --rbind /$d /mnt/ufs/$d
  mount --make-rslave /mnt/ufs/$d
done
```

Without these, kernel postinst scripts can't build initramfs,
`grub-install` can't probe the ESP, and systemd presets don't apply.
`--make-rslave` stops unmount propagation from nuking the host's mounts.

### 7. Drop config into the rootfs

- `/etc/hostname`
- `/etc/hosts`
- `/etc/fstab` (LABEL=root, LABEL=ESP)
- `/etc/netplan/01-netcfg.yaml`
- `/etc/apt/sources.list` (main + updates + security)
- `/usr/local/sbin/firstboot.sh`
- `/etc/systemd/system/firstboot.service`
- clears `/etc/machine-id` so it regenerates on first boot

### 8. Finish inside the chroot

```bash
chroot /mnt/ufs /bin/bash -eux <<'CHROOT'
useradd -m -s /bin/bash -G sudo ubuntu
echo ubuntu:ubuntu | chpasswd
passwd -l root
systemctl enable ssh systemd-networkd systemd-resolved firstboot.service
apt-get purge -y snapd ubuntu-advantage-tools
apt-get autoremove -y
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
  --bootloader-id=ubuntu --removable --no-nvram
update-grub
CHROOT
```

`--removable` writes `/EFI/BOOT/BOOTX64.EFI`, the default path EFI
firmware searches when no NVRAM entry exists. That's what makes the
image portable — it boots on any EFI firmware without needing the
firmware's boot order to be populated first.

### 9. Unmount cleanly

Tear down in reverse order, release the loop device, and you have a
bootable raw image at `build/ubuntu.img`.

---

## `config/` reference

| File | Role | Autoinstall counterpart |
|---|---|---|
| `packages.list` | apt package set installed during debootstrap | `packages:` block in `user-data` |
| `netplan.yaml` | installed as `/etc/netplan/01-netcfg.yaml` | `network:` block in `user-data` |
| `firstboot.sh` | runs once on first boot, then disables itself | inline in `write_files:` |
| `firstboot.service` | systemd unit that triggers firstboot.sh | inline in `write_files:` |

`packages.list` syntax is one package per line; `#` starts a comment;
blank lines ignored. `build.sh` joins them with commas and passes the
result to `debootstrap --include=`.

### Adding a third-party apt repo

Unlike autoinstall, there's no built-in `apt: sources:` block — you
just extend the chroot step in `build.sh`:

```bash
chroot "$MNT" /bin/bash -eux <<'CHROOT'
install -D -m 0644 /tmp/docker.gpg /usr/share/keyrings/docker.gpg
echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu resolute stable' \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli
CHROOT
```

Stage the key inside `config/` and copy it in before the chroot block.

---

## First boot

`firstboot.service` is `Type=oneshot` + `ConditionPathExists=!/etc/firstboot-complete`.
On the first real boot it:

1. Regenerates `/etc/machine-id` (debootstrap left it empty).
2. Regenerates SSH host keys (build time had none, or they were cloned).
3. Drops `/etc/firstboot-complete` as proof.
4. Disables itself.

Why this matters: if you `dd` the image to 100 servers, they must each
get unique SSH host keys and a unique machine-id on boot. Skipping this
step is how you end up with 100 hosts sharing an identity.

---

## Golden image — sysprep before you clone

If you're going to deploy this image elsewhere, shut it down cleanly
and strip per-instance state before you snapshot/copy:

```bash
# inside the running VM, right before you power it off for the last time
sudo cloud-init clean --logs --machine-id    # if cloud-init is installed
sudo rm -f /etc/ssh/ssh_host_*
sudo rm -rf /var/log/journal/*
sudo rm -rf /var/lib/dbus/machine-id /etc/machine-id
sudo truncate -s 0 /etc/machine-id           # keep the file, empty contents
sudo rm -rf /tmp/* /var/tmp/*
sudo apt-get clean
sudo shutdown -h now       # halt, do NOT reboot — reboot regenerates host keys
```

`firstboot.service` is the counterpart on the *receive* side: it ensures
the clone regenerates anything sysprep wiped.

---

## Compress & store

After sysprep, shrink and compress the image:

```bash
# fill free space with zeros so xz can compress them away
sudo virt-sparsify --compress build/ubuntu.img build/ubuntu.sparse.img
xz -T0 -9 build/ubuntu.sparse.img
sha256sum build/ubuntu.sparse.img.xz > build/ubuntu.sparse.img.xz.sha256
```

Typical results: an 8 GiB raw image with ~1.5 GiB used compresses to
300–500 MB. That's the artifact you publish.

---

## Deploy to bare metal

Two common paths:

### `dd` via SSH

```bash
xzcat ubuntu.sparse.img.xz | ssh root@target 'dd of=/dev/nvme0n1 bs=8M status=progress'
```

### iPXE + boot script

Serve the compressed image over HTTPS and boot from a rescue shell or a
netboot menu that `wget`s + pipes into `dd`. This is usually wrapped by
a small factory utility that also verifies the sha256 before writing.

In either case the target hardware boots the image and `firstboot.service`
individualizes it.

---

## Nightly `apt`

The golden image is intentionally dumb — every deployed server is
identical at boot. Customer-specific or site-specific state arrives
after deployment via `unattended-upgrades` pointing at a controlled
artifact repo:

```yaml
# /etc/apt/apt.conf.d/50unattended-upgrades
Unattended-Upgrade::Origins-Pattern {
  "origin=MyCompany";
};
```

Ship your config as a `.deb` with a `postinst` that applies
site-specific setup. The image never knows who its customer is until
the first nightly apt run.

---

## Verification

After boot, the same checks as the autoinstall path work:

```bash
ssh -p 2222 ubuntu@localhost                # password: ubuntu
sudo systemctl status firstboot.service     # expect: inactive, disabled
sudo cat /etc/firstboot-complete            # marker
sudo cat /var/log/firstboot.log             # firstboot stdout
```

Plus a few debootstrap-specific sanity checks:

```bash
cat /etc/machine-id              # non-empty, 32 hex chars
ls /etc/ssh/ssh_host_*           # host keys exist
findmnt /                        # LABEL=root
findmnt /boot/efi                # LABEL=ESP
efibootmgr                       # or: bootctl list
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `E: No such script: /usr/share/debootstrap/scripts/resolute` | host's `debootstrap` pre-dates 26.04 | `sudo ln -s gutsy /usr/share/debootstrap/scripts/resolute`, or upgrade `debootstrap` from `-updates` / `-backports` |
| `debootstrap: error: Invalid Release signature` | clock skew inside the chroot (common in fresh VMs) | `sudo timedatectl set-ntp true` on the host |
| `grub-install: failed to get canonical path of '/cow'` | bind mounts missing or `chroot` lost its pseudo-fs | re-run the `mount --rbind` loop; make sure `--make-rslave` was applied |
| VM boots to the EFI shell instead of GRUB | EFI firmware didn't find a bootloader | confirm `/EFI/BOOT/BOOTX64.EFI` exists in the ESP; `--removable` on `grub-install` is what writes it |
| `firstboot.service` never disabled itself | script errored before reaching `systemctl disable` | `journalctl -u firstboot.service` — fix, delete `/etc/firstboot-complete`, re-run |
| netplan brings up nothing | interface isn't `en*` on this hypervisor | edit `config/netplan.yaml` match rule, rebuild |
| "read-only filesystem" mid-build | loop device snapped off | `losetup -l` to inspect; clean up with `losetup -D`; rerun |
| image won't boot after `dd` to real disk | target has Secure Boot, `shim-signed` missing or GRUB unsigned | keep `shim-signed` in `packages.list`, or disable Secure Boot |

### Inspect a built image without booting it

```bash
LOOP=$(sudo losetup --find --show --partscan build/ubuntu.img)
sudo mount "${LOOP}p2" /mnt
sudo ls /mnt/etc/systemd/system
# ... poke around ...
sudo umount /mnt
sudo losetup -d "$LOOP"
```

Useful for confirming firstboot.service landed, packages are present,
grub.cfg looks sane, etc., before you spend VirtualBox minutes finding
out the hard way.
