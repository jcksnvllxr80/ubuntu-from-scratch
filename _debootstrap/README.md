# ubuntu-from-scratch — debootstrap approach

A working, minimal **Ubuntu 26.04 LTS** (Resolute Raccoon) server image
built straight from the Ubuntu archive with `debootstrap` and booted in
VirtualBox. No installer ISO download, no Subiquity, no "Continue with
autoinstall?" prompt — the rootfs is assembled in one script and boots
as a finished system.
`firstboot.service` runs once on the first real boot. No desktop —
desktop packages live in `config/packages.list` as labeled comment blocks
you can uncomment later.

Two build paths ship here, picking whichever fits your host:

- **[Linux / WSL](#approach-a--linux--wsl)** — `build.sh` + `run-vm.sh`
- **[Windows (PowerShell)](#approach-b--windows-powershell)** — `build.ps1` + `run-vm.ps1`

macOS can run `run-vm.sh` (if you produce the raw image elsewhere), but
`build.sh` itself needs Linux — debootstrap, loop-mount, and chroot don't
work on macOS. Build inside a Linux VM / multipass instance / remote
host, then copy `build/ubuntu.img` over and boot it locally.

Both paths produce the same `build/ubuntu.img` and drive the same
VirtualBox VM. Pick one and stick with it.

For the counterpart "download Ubuntu's ISO and let Subiquity install it"
approach, see [`../_autoinstall/README.md`](../_autoinstall/README.md).
For a side-by-side comparison, see the [parent README](../README.md).

---

## Contents

1. [Layout](#layout)
2. [Approach A — Linux / WSL](#approach-a--linux--wsl)
3. [Approach B — Windows (PowerShell)](#approach-b--windows-powershell)
4. [Verify firstboot ran](#verify-firstboot-ran)
5. [Adding or removing packages](#adding-or-removing-packages)
6. [Updating the kernel](#updating-the-kernel)
7. [Adding a desktop](#adding-a-desktop)
8. [Tunables](#tunables)
9. [Rebuild / rerun](#rebuild--rerun)
10. [Troubleshooting](#troubleshooting)
11. [Out of scope](#out-of-scope)

---

## Layout

```
_debootstrap/
├── README.md                     # this file
├── config/
│   ├── packages.list             # apt packages installed during bootstrap
│   ├── netplan.yaml              # /etc/netplan/01-netcfg.yaml
│   ├── firstboot.sh              # runs once on first boot
│   └── firstboot.service         # systemd unit that triggers firstboot.sh
├── build.sh                      # Linux/WSL — builds build/ubuntu.img (raw)
├── run-vm.sh                     # Linux/macOS/WSL/Git Bash — creates + boots VM
├── build.ps1                     # Windows PowerShell — wraps WSL to run build.sh
├── run-vm.ps1                    # Windows PowerShell — creates + boots VM
├── build/                        # generated (ubuntu.img, VM disk) — gitignored
└── docs/
    ├── ubuntu-debootstrap.md     # full pipeline reference (sysprep, compress, deploy)
    └── ubuntu-debootstrap.html   # same content, rendered
```

Everything you tune lives in `config/`. The build scripts are mechanical —
you shouldn't need to edit them for normal changes.

No Ubuntu ISO download — `debootstrap` fetches packages straight from
`http://archive.ubuntu.com/ubuntu` (override with `MIRROR=…` if you run
a local mirror).

---

## Approach A — Linux / WSL

Use this path on Ubuntu, WSL, or a Linux VM. `build.sh` needs
`debootstrap` + `parted` + `dosfstools` + `openssl`, and runs as root.

### Prerequisites

| Tool | WSL / Ubuntu | Windows (Git Bash) |
|---|---|---|
| VirtualBox | run from host | [virtualbox.org](https://www.virtualbox.org/) |
| debootstrap + parted + dosfstools + openssl | `sudo apt install debootstrap parted dosfstools openssl` | run `build.ps1` (uses WSL) |
| root / sudo | yes | — |

### Build and boot

```bash
# 1. Build build/ubuntu.img (defaults: user=ubuntu, password=ubuntu)
sudo ./build.sh
# or: sudo PASSWORD=mypass ./build.sh

# 2. Convert to VDI, create an EFI VM, boot it
./run-vm.sh
```

Tunables are environment variables — see [Tunables](#tunables).

---

## Approach B — Windows (PowerShell)

`debootstrap` is Linux-only, so `build.ps1` wraps WSL: it runs `build.sh`
inside your WSL Ubuntu distro. The produced image lives on the Windows
side; `run-vm.ps1` drives VirtualBox natively from Windows.

`build.ps1` **checks** for WSL and its required tools but does not install
anything — see Prerequisites below. Do the one-time setup first, then
every build is a single command.

### Prerequisites (one-time setup)

| Tool | How to get it |
|---|---|
| PowerShell 5.1+ | ships with Windows 10/11 |
| VirtualBox | [virtualbox.org](https://www.virtualbox.org/) or `winget install Oracle.VirtualBox` |
| WSL + an Ubuntu distro | `wsl --install -d Ubuntu` (reboot if prompted) |
| Build tools inside WSL | `wsl -- sudo apt install -y debootstrap parted dosfstools openssl` |

If PowerShell refuses to run the scripts, either invoke with
`-ExecutionPolicy Bypass` (as shown) or allow scripts for your user:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
Unblock-File .\build.ps1, .\run-vm.ps1
```

### Build and boot

```powershell
# 1. Build build\ubuntu.img via WSL (defaults: user=ubuntu, password=ubuntu)
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
# or: $env:PASSWORD='mypass'; .\build.ps1
# or: .\build.ps1 -Distro Ubuntu-24.04

# 2. Convert to VDI, create an EFI VM, boot it
powershell -NoProfile -ExecutionPolicy Bypass -File .\run-vm.ps1
```

Tunables are environment variables or `-Param` flags — see
[Tunables](#tunables).

---

## Verify firstboot ran

Same on both paths. The VM boots straight from the disk — no installer,
no GRUB menu prompt. firstboot regenerates the machine-id and SSH host
keys on first boot, then disables itself.

```bash
ssh -p 2222 ubuntu@localhost              # password: ubuntu

sudo systemctl status firstboot.service   # expect: inactive (ran + disabled)
sudo cat /etc/firstboot-complete          # marker written by firstboot.sh
sudo cat /var/log/firstboot.log           # firstboot stdout
```

---

## Adding or removing packages

Everything is driven by `config/packages.list`, no matter which build
script you use. One package per line; `#` starts a comment; blank lines
ignored. `build.sh` joins them with commas and passes the result to
`debootstrap --include=`.

### Add a package from the standard Ubuntu archives

Edit `config/packages.list`:

```
# ---- parity with the autoinstall default set ----
curl
wget
htop
vim
tmux       # <- new
git        # <- new
```

Then rebuild + boot again (Approach A or B).

### Remove a package

Delete the line. If a package you don't want comes in as a transitive
dependency, purge it in the chroot block inside `build.sh`:

```bash
chroot "$MNT" /bin/bash -eux <<CHROOT
...
apt-get purge -y snapd ubuntu-advantage-tools motd-news-config byobu
apt-get autoremove -y
...
CHROOT
```

### Install from a third-party apt repo

There's no built-in `apt: sources:` block like autoinstall has — you
extend the chroot step in `build.sh` directly. Docker as an example:

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

Stage the key under `config/` and copy it into the chroot before the
block runs.

### Install a local `.deb`

```bash
# before the chroot block: stage into the rootfs
install -D -m 0644 config/your-pkg_1.0_amd64.deb "$MNT/tmp/your-pkg.deb"

# inside the chroot block:
chroot "$MNT" /bin/bash -eux <<'CHROOT'
dpkg -i /tmp/your-pkg.deb || apt-get install -fy
rm /tmp/your-pkg.deb
CHROOT
```

### Change something on the running VM (no rebuild)

Once the VM is up, it's a normal Ubuntu box:

```bash
sudo apt update
sudo apt install <pkg>         # add
sudo apt purge <pkg>           # remove
sudo apt autoremove
```

Use `config/packages.list` for anything that must be present on every
freshly built image. Use `apt install` for one-off tweaks on a VM
you've already built.

---

## Updating the kernel

Ubuntu ships two kernel tracks on LTS:

| Meta-package | Kernel | Notes |
|---|---|---|
| `linux-generic` | GA (frozen at release) | default, security updates for the full LTS window |
| `linux-generic-hwe-XX.YY` | HWE (rolls forward) | newer hardware support, tracks latest point release |

### Switch to the HWE kernel at build time

Add it to `config/packages.list`:

```
linux-generic
linux-generic-hwe-26.04    # <- HWE kernel, newer than the GA default
```

Rebuild. The HWE meta-package coexists with `linux-generic` and GRUB
boots the newer kernel by default.

### Pin a specific kernel version

```
linux-image-X.Y.Z-generic
linux-headers-X.Y.Z-generic
```

List what's actually available with `apt-cache search '^linux-image-[0-9].*generic$'`
on a running 26.04 box.

### Update the kernel on an already-built VM

```bash
sudo apt update
sudo apt full-upgrade
sudo reboot
uname -r
```

### Clean up old kernels

```bash
sudo apt autoremove --purge
dpkg -l 'linux-image-*' | grep ^ii
```

---

## Adding a desktop

Two sections are labeled in `config/packages.list`:

- `DESKTOP PACKAGES` / `END DESKTOP PACKAGES` — GNOME + GDM meta-packages
- `DESKTOP-ONLY FIRSTBOOT STEPS` / `END DESKTOP-ONLY` — inside `config/firstboot.sh`

Uncomment the lines in both, rerun the build + VM scripts, and the
installed VM boots into a GNOME login screen. Bump `MEMORY_MB` to
4096+ and `SIZE_MB` to 25000+ for a comfortable desktop experience.

---

## Tunables

Same semantics on both paths; set them via environment variables.
PowerShell also accepts named `-Param` flags where relevant.

| Variable | Default | Used by | Notes |
|---|---|---|---|
| `PASSWORD` | `ubuntu` | build scripts | plain text; chpasswd'd in the chroot |
| `USERNAME` | `ubuntu` | build scripts | login user inside the image |
| `HOSTNAME_` | `ubuntu-minimal` | build scripts | guest hostname (trailing `_` avoids clashing with bash's built-in `HOSTNAME`) |
| `SUITE` | `resolute` | build scripts | Ubuntu codename (26.04 LTS = Resolute Raccoon) |
| `MIRROR` | `http://archive.ubuntu.com/ubuntu` | build scripts | use a local mirror to skip the internet round-trip |
| `SIZE_MB` | `8192` | `build.sh` | raw image size in MiB |
| `WSL_DISTRO` | (default distro) | `build.ps1` | which WSL distro to shell into |
| `VM_NAME` | `ubuntu-minimal` | run-vm scripts | VirtualBox VM name |
| `MEMORY_MB` | `4096` | run-vm scripts | RAM |
| `CPUS` | `2` | run-vm scripts | |
| `SSH_PORT` | `2222` | run-vm scripts | host port forwarded to guest 22 |

Bash:

```bash
sudo PASSWORD='s3cret' SIZE_MB=16384 ./build.sh
VM_NAME=ubuntu-desktop MEMORY_MB=8192 ./run-vm.sh
```

PowerShell:

```powershell
$env:PASSWORD = 's3cret'
$env:SIZE_MB  = '16384'
.\build.ps1

.\run-vm.ps1 -VmName ubuntu-desktop -MemoryMb 8192
```

---

## Rebuild / rerun

Both `run-vm.sh` and `run-vm.ps1` destroy any existing VM with the same
`VM_NAME` and rebuild from the raw image. To iterate:

```
# edit config/packages.list or config/firstboot.sh
# then re-run build + run-vm for your path
```

Nothing outside `build/` and the VirtualBox VM registry is touched.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `E: No such script: /usr/share/debootstrap/scripts/resolute` | host's `debootstrap` pre-dates 26.04 | `sudo ln -s gutsy /usr/share/debootstrap/scripts/resolute` (uses the generic script), or upgrade `debootstrap` from `-updates` / `-backports` |
| `debootstrap: error: Invalid Release signature` | host clock skew | `sudo timedatectl set-ntp true` on the host, retry |
| `losetup: failed to set up loop device` | prior build didn't clean up | `sudo losetup -D` to release all; retry |
| `grub-install: failed to get canonical path of '/cow'` | chroot missing `/dev`, `/proc`, `/sys` | bind mounts got dropped — re-run the `mount --rbind` loop |
| VM boots to EFI shell instead of GRUB | EFI firmware didn't find a bootloader | confirm `/EFI/BOOT/BOOTX64.EFI` exists on the ESP; `grub-install --removable` is what writes it |
| VM boots but no network | netplan match rule (`en*`) doesn't match the NIC | edit `config/netplan.yaml`, rebuild |
| SSH "connection refused" on 2222 | firstboot still running, or ssh not enabled | wait 30–60s; `VBoxManage showvminfo "$VM_NAME"` |
| `firstboot-complete` missing after boot | `firstboot.service` failed | `ssh` in, `journalctl -u firstboot.service` |
| `wsl.exe not found` (Windows) | WSL not installed | `wsl --install -d Ubuntu`, reboot |
| PowerShell: script refuses to run | execution policy | run with `-ExecutionPolicy Bypass` or `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |

### Inspect the built image without booting it

```bash
LOOP=$(sudo losetup --find --show --partscan build/ubuntu.img)
sudo mount "${LOOP}p2" /mnt
sudo ls /mnt/etc/systemd/system/
sudo umount /mnt
sudo losetup -d "$LOOP"
```

Useful for confirming firstboot.service landed, packages are present,
and grub.cfg looks sane, before you spend VirtualBox minutes finding out
the hard way.

---

## Out of scope

Sysprep, compression to `.raw.xz`, publishing a golden image, and
nightly-apt delivery are covered in
[`docs/ubuntu-debootstrap.md`](docs/ubuntu-debootstrap.md). This example
stops once firstboot has run — enough to prove the debootstrap + firstboot
pipeline works end to end in VirtualBox.
